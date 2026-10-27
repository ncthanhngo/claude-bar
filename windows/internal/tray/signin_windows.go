//go:build windows

package tray

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"syscall"
	"time"

	webview2 "github.com/jchv/go-webview2"
)

// SignInFlag makes ClaudeSwap.exe run only the sign-in window (see
// SignInMain). The window lives in its own short-lived process: WebView2's
// helper processes exit with it, and a WebView2 failure can't take the tray
// down.
const SignInFlag = "--sign-in"

// Exit codes of the sign-in process.
const (
	signInExitClosed      = 3
	signInExitNoWebView   = 4
	signInExitNeedsSignIn = 5
	signInExitTimeout     = 6
)

var (
	// errNoWebView means the WebView2 runtime is missing; the caller falls
	// back to the default browser and a pasted code.
	errNoWebView = errors.New("WebView2 is not available")
	// errSignInClosed means the user closed the window before signing in.
	errSignInClosed = errors.New("sign-in window closed")
	// errNeedsSignIn means a background re-login found the claude.ai session
	// gone: only the user can sign in again.
	errNeedsSignIn = errors.New("the claude.ai session has ended")
	// errSignInTimeout means a background re-login did not finish in time.
	errSignInTimeout = errors.New("background sign-in timed out")
)

// headlessTimeout bounds an unattended re-login (macOS uses 30s).
const headlessTimeout = 45 * time.Second

// The authorize flow ends on the manual-code callback page; its URL carries
// code and state. The page lives on platform.claude.com now
// (console.anthropic.com before), so accept either.
const callbackScript = `(function () {
  var hosts = ['platform.claude.com', 'console.anthropic.com'];
  if (hosts.indexOf(location.hostname) >= 0 &&
      location.pathname === '/oauth/code/callback' &&
      new URLSearchParams(location.search).get('code')) {
    window.cswSignedIn(location.href);
  }
})();`

// headlessScript drives the consent page without a user, like macOS's
// OAuthWebScripts: click the primary "Authorize" button once it appears,
// and report a login page (the saved session is gone) instead of waiting.
const headlessScript = `(function () {
  var wanted = ['authorize', 'authorise'];
  var deny = ['cancel', 'deny', 'reject', 'go back', 'back', 'not now'];
  var clicked = false;
  function tick() {
    var path = location.pathname.toLowerCase();
    if (location.hostname.endsWith('claude.ai') &&
        (path.indexOf('/login') === 0 || document.querySelector('input[type="password"]'))) {
      window.cswNeedsSignIn();
      return;
    }
    if (!clicked && /\/oauth\/authorize/.test(location.pathname)) {
      var els = document.querySelectorAll('button, [role="button"], input[type="submit"]');
      for (var i = 0; i < els.length; i++) {
        var el = els[i];
        if (el.disabled) continue;
        var t = (el.innerText || el.value || el.textContent || '').trim().toLowerCase();
        if (!t || deny.indexOf(t) >= 0) continue;
        if (wanted.indexOf(t) >= 0 || wanted.some(function (w) { return t.indexOf(w + ' ') === 0; })) {
          clicked = true;
          el.click();
          break;
        }
      }
    }
  }
  setInterval(tick, 500);
})();`

// signInOpts configures one run of the sign-in window process.
type signInOpts struct {
	URL      string
	Profile  string // WebView2 profile dir; "" = throwaway
	Headless bool   // hidden window, auto-authorize, give up on a login page
}

// signInWindow runs the sign-in window process and returns "code#state".
func signInWindow(o signInOpts) (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	args := []string{SignInFlag}
	if o.Profile != "" {
		args = append(args, "--profile", o.Profile)
	}
	if o.Headless {
		args = append(args, "--headless")
	}
	args = append(args, o.URL)

	ctx := context.Background()
	if o.Headless {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, headlessTimeout+15*time.Second)
		defer cancel()
	}
	var stdout bytes.Buffer
	cmd := exec.CommandContext(ctx, exe, args...)
	cmd.Stdout = &stdout
	if o.Headless {
		// The first ShowWindow of the child then hides instead of shows.
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	}
	err = cmd.Run()
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		switch exit.ExitCode() {
		case signInExitClosed:
			return "", errSignInClosed
		case signInExitNoWebView:
			return "", errNoWebView
		case signInExitNeedsSignIn:
			return "", errNeedsSignIn
		case signInExitTimeout:
			return "", errSignInTimeout
		}
		if ctx.Err() != nil {
			return "", errSignInTimeout
		}
		return "", fmt.Errorf("sign-in window failed (exit %d)", exit.ExitCode())
	}
	if err != nil {
		return "", err
	}
	code := strings.TrimSpace(stdout.String())
	if code == "" {
		return "", errSignInClosed
	}
	return code, nil
}

// SignInMain is the sign-in process (args after SignInFlag:
// [--profile DIR] [--headless] URL). It shows claude.ai's sign-in in a
// WebView2 window and prints "code#state" once the callback page loads.
// Without --profile it uses a throwaway profile so no existing claude.ai
// session is reused silently.
func SignInMain(args []string) {
	runtime.LockOSThread()

	var profile, authURL string
	headless := false
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--profile" && i+1 < len(args):
			i++
			profile = args[i]
		case args[i] == "--headless":
			headless = true
		default:
			authURL = args[i]
		}
	}
	throwaway := profile == ""
	if throwaway {
		dir, err := os.MkdirTemp("", "ClaudeSwapSignIn-")
		if err != nil {
			os.Exit(1)
		}
		profile = dir
	} else if err := os.MkdirAll(profile, 0o700); err != nil {
		os.Exit(1)
	}
	cleanup := func() {
		if throwaway {
			removeProfileDir(profile)
		}
	}

	w := webview2.NewWithOptions(webview2.WebViewOptions{
		DataPath:  profile,
		AutoFocus: !headless,
		WindowOptions: webview2.WindowOptions{
			Title:  appTitle + " — Sign in to Claude",
			Width:  520,
			Height: 760,
			Center: true,
		},
	})
	if w == nil {
		cleanup()
		os.Exit(signInExitNoWebView)
	}
	var callback string
	exitCode := signInExitClosed
	_ = w.Bind("cswSignedIn", func(href string) {
		if callback == "" {
			callback = href
			w.Dispatch(w.Destroy)
		}
	})
	w.Init(callbackScript)
	if headless {
		_ = w.Bind("cswNeedsSignIn", func() {
			if callback == "" && exitCode == signInExitClosed {
				exitCode = signInExitNeedsSignIn
				w.Dispatch(w.Destroy)
			}
		})
		w.Init(headlessScript)
		time.AfterFunc(headlessTimeout, func() {
			w.Dispatch(func() {
				if callback == "" && exitCode == signInExitClosed {
					exitCode = signInExitTimeout
					w.Destroy()
				}
			})
		})
	}
	w.Navigate(authURL)
	w.Run() // returns when the window is closed

	code := codeFromCallback(callback)
	cleanup()
	if code == "" {
		os.Exit(exitCode)
	}
	fmt.Println(code)
	os.Exit(0)
}

// codeFromCallback turns the callback URL into "code#state"; "" if absent.
func codeFromCallback(callback string) string {
	u, err := url.Parse(callback)
	if err != nil {
		return ""
	}
	q := u.Query()
	if q.Get("code") == "" {
		return ""
	}
	return q.Get("code") + "#" + q.Get("state")
}

// removeProfileDir deletes a WebView2 profile, waiting briefly for its
// helper processes to let go of it.
func removeProfileDir(dir string) {
	for i := 0; i < 20; i++ {
		if os.RemoveAll(dir) == nil {
			return
		}
		time.Sleep(500 * time.Millisecond)
	}
}
