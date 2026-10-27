//go:build windows

package tray

import (
	_ "embed"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"time"
	"unsafe"

	webview2 "github.com/jchv/go-webview2"
	"golang.org/x/sys/windows"
)

//go:embed popover.html
var popoverHTML string

// popoverWidth is the popover's width in CSS pixels (macOS Medium is 300).
const popoverWidth = 320

var (
	user32                  = windows.NewLazySystemDLL("user32.dll")
	procGetCursorPos        = user32.NewProc("GetCursorPos")
	procMonitorFromPoint    = user32.NewProc("MonitorFromPoint")
	procGetMonitorInfoW     = user32.NewProc("GetMonitorInfoW")
	procSetWindowLongPtrW   = user32.NewProc("SetWindowLongPtrW")
	procSetWindowPos        = user32.NewProc("SetWindowPos")
	procShowWindow          = user32.NewProc("ShowWindow")
	procSetForegroundWindow = user32.NewProc("SetForegroundWindow")
	shcore                  = windows.NewLazySystemDLL("shcore.dll")
	procGetDpiForMonitor    = shcore.NewProc("GetDpiForMonitor")
	dwmapi                  = windows.NewLazySystemDLL("dwmapi.dll")
	procDwmSetWindowAttr    = dwmapi.NewProc("DwmSetWindowAttribute")
)

const (
	gwlStyle              = ^uintptr(15) // -16
	gwlExStyle            = ^uintptr(19) // -20
	wsPopup               = 0x80000000
	wsExToolWindow        = 0x00000080
	wsExTopmost           = 0x00000008
	swHide                = 0
	swShow                = 5
	swpNoActivate         = 0x0010
	swpFrameChanged       = 0x0020
	hwndTopmost           = ^uintptr(0) // -1
	monitorDefaultNearest = 2
	dwmwaCornerPreference = 33
	dwmwcpRound           = 2
)

type point struct{ X, Y int32 }
type rect struct{ Left, Top, Right, Bottom int32 }
type monitorInfo struct {
	Size    uint32
	Monitor rect
	Work    rect
	Flags   uint32
}

// popover is the left-click window: an HTML account list in WebView2,
// like the macOS popover. It is created on first use and then only hidden
// and shown; it lives on its own locked OS thread with its own message
// loop, separate from the tray's.
type popover struct {
	onAction func(action string, num int) // runs on a fresh goroutine

	mu       sync.Mutex
	w        webview2.WebView
	hwnd     uintptr
	visible  bool
	hiddenAt time.Time
	height   int        // content height in CSS px, reported by the page
	anchor   point      // cursor position of the click that opened it
	state    []byte     // last state JSON, replayed when the page loads
	started  chan error // closed once the window exists (nil error) or failed
}

func newPopover(onAction func(string, int)) *popover {
	return &popover{onAction: onAction, height: 360}
}

// Toggle shows the popover near the cursor, or hides it if open. A click on
// the tray icon first blurs (and hides) an open popover; that click must not
// immediately re-open it.
func (p *popover) Toggle() {
	p.mu.Lock()
	if p.visible {
		p.mu.Unlock()
		p.Hide()
		return
	}
	recent := time.Since(p.hiddenAt) < 400*time.Millisecond
	p.mu.Unlock()
	if recent {
		return
	}
	var pt point
	procGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
	if err := p.ensure(); err != nil {
		showError("Could not open the Claude Swap window", err)
		return
	}
	p.mu.Lock()
	p.anchor = pt
	w := p.w
	p.mu.Unlock()
	w.Dispatch(func() {
		p.place()
		procShowWindow.Call(p.hwnd, swShow)
		procSetForegroundWindow.Call(p.hwnd) // AutoFocus then focuses the page
		p.mu.Lock()
		p.visible = true
		p.mu.Unlock()
		w.Eval("window.onShown && window.onShown()")
	})
	go p.onAction("shown", 0)
}

// Hide hides the popover (it keeps running).
func (p *popover) Hide() {
	p.mu.Lock()
	w := p.w
	p.mu.Unlock()
	if w == nil {
		return
	}
	w.Dispatch(func() {
		procShowWindow.Call(p.hwnd, swHide)
		p.mu.Lock()
		p.visible = false
		p.hiddenAt = time.Now()
		p.mu.Unlock()
	})
}

// Visible reports whether the popover is on screen.
func (p *popover) Visible() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.visible
}

// SetState sends the tray state to the page (and keeps it for reloads).
func (p *popover) SetState(state any) {
	b, err := json.Marshal(state)
	if err != nil {
		return
	}
	p.mu.Lock()
	p.state = b
	w := p.w
	p.mu.Unlock()
	if w != nil {
		w.Dispatch(func() { w.Eval("window.render && window.render(" + string(b) + ")") })
	}
}

// ensure creates the window on first use and waits until it exists.
func (p *popover) ensure() error {
	p.mu.Lock()
	if p.started == nil {
		p.started = make(chan error, 1)
		go p.run(p.started)
	}
	started := p.started
	p.mu.Unlock()
	err := <-started
	started <- err // keep the result for later callers
	if err != nil {
		p.mu.Lock()
		p.started = nil // try again next click
		p.mu.Unlock()
	}
	return err
}

func (p *popover) run(started chan error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	dataDir := filepath.Join(os.Getenv("LOCALAPPDATA"), "ClaudeSwap", "webview")
	_ = os.MkdirAll(dataDir, 0o700)
	w := webview2.NewWithOptions(webview2.WebViewOptions{
		DataPath:      dataDir,
		AutoFocus:     true,
		WindowOptions: webview2.WindowOptions{Title: appTitle, Width: popoverWidth, Height: 360},
	})
	if w == nil {
		started <- errNoWebView
		return
	}
	hwnd := uintptr(w.Window())
	procShowWindow.Call(hwnd, swHide)
	procSetWindowLongPtrW.Call(hwnd, gwlStyle, wsPopup)
	procSetWindowLongPtrW.Call(hwnd, gwlExStyle, wsExToolWindow|wsExTopmost)
	procSetWindowPos.Call(hwnd, hwndTopmost, 0, 0, 0, 0, swpNoActivate|swpFrameChanged|0x0001|0x0002) // NOSIZE|NOMOVE
	corner := uint32(dwmwcpRound)
	procDwmSetWindowAttr.Call(hwnd, dwmwaCornerPreference, uintptr(unsafe.Pointer(&corner)), 4) // Windows 11 only

	_ = w.Bind("cswReady", func() {
		p.mu.Lock()
		state := p.state
		p.mu.Unlock()
		if state != nil {
			w.Eval("window.render(" + string(state) + ")")
		}
	})
	_ = w.Bind("cswResize", func(h int) {
		p.mu.Lock()
		p.height = h
		visible := p.visible
		p.mu.Unlock()
		if visible {
			p.place()
		}
	})
	_ = w.Bind("cswHide", func() { p.Hide() })
	_ = w.Bind("cswAction", func(action string, num int) {
		go p.onAction(action, num)
	})
	_ = w.Bind("cswLog", func(msg string) { logf("popover js: %s", msg) })
	w.SetHtml(popoverHTML)

	p.mu.Lock()
	p.w, p.hwnd = w, hwnd
	p.mu.Unlock()
	started <- nil

	w.Run() // returns only if the window is destroyed (e.g. Alt+F4)

	p.mu.Lock()
	p.w, p.hwnd, p.visible, p.started = nil, 0, false, nil
	p.mu.Unlock()
}

// place sizes the popover and puts it next to the taskbar, centred on the
// click, inside the monitor's work area. Runs on the window's thread.
func (p *popover) place() {
	p.mu.Lock()
	anchor, cssH, hwnd := p.anchor, p.height, p.hwnd
	p.mu.Unlock()

	mon, _, _ := procMonitorFromPoint.Call(uintptr(*(*uint64)(unsafe.Pointer(&anchor))), monitorDefaultNearest)
	mi := monitorInfo{Size: uint32(unsafe.Sizeof(monitorInfo{}))}
	procGetMonitorInfoW.Call(mon, uintptr(unsafe.Pointer(&mi)))
	var dpiX, dpiY uint32 = 96, 96
	procGetDpiForMonitor.Call(mon, 0, uintptr(unsafe.Pointer(&dpiX)), uintptr(unsafe.Pointer(&dpiY)))
	scale := float64(dpiX) / 96

	work, full := mi.Work, mi.Monitor
	margin := int32(12 * scale)
	w := int32(popoverWidth * scale)
	h := int32(float64(cssH) * scale)
	if maxH := work.Bottom - work.Top - 2*margin; h > maxH {
		h = maxH
	}

	x, y := anchor.X-w/2, work.Bottom-h-margin // taskbar at the bottom (or auto-hide)
	switch {
	case work.Top > full.Top:
		y = work.Top + margin
	case work.Left > full.Left:
		x, y = work.Left+margin, anchor.Y-h/2
	case work.Right < full.Right:
		x, y = work.Right-w-margin, anchor.Y-h/2
	}
	x = clamp(x, work.Left+margin, work.Right-w-margin)
	y = clamp(y, work.Top+margin, work.Bottom-h-margin)
	procSetWindowPos.Call(hwnd, hwndTopmost, uintptr(x), uintptr(y), uintptr(w), uintptr(h), swpNoActivate)
}

func clamp(v, lo, hi int32) int32 {
	if v > hi {
		v = hi
	}
	if v < lo {
		v = lo
	}
	return v
}
