package cswclient

import (
	"context"
	"errors"
	"reflect"
	"testing"
)

type recorder struct {
	args  [][]string
	stdin []string
	out   string
	err   error
}

func (r *recorder) run(_ context.Context, stdin []byte, args ...string) ([]byte, error) {
	r.args = append(r.args, args)
	r.stdin = append(r.stdin, string(stdin))
	return []byte(r.out), r.err
}

func TestListDecodesAccounts(t *testing.T) {
	r := &recorder{out: `{"accounts":[{"account":{"number":1,"email":"a@x.com"},"isActive":true},{"account":{"number":2,"email":"b@x.com","nickname":"Work"},"isActive":false}],"activeAccountNumber":1}`}
	res, err := NewWithRunner(r.run).List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(r.args[0], []string{"list", "--json", "--metadata-only"}) {
		t.Fatalf("args %v", r.args[0])
	}
	if res.ActiveAccountNumber != 1 || len(res.Accounts) != 2 || res.Accounts[1].Account.DisplayName() != "Work" || res.Accounts[0].Account.DisplayName() != "a@x.com" {
		t.Fatalf("result %+v", res)
	}
}

func TestCommandArgsPutFlagsBeforePositionals(t *testing.T) {
	r := &recorder{out: `{"account":{"number":3,"email":"c@x.com"},"wasDuplicate":false}`}
	c := NewWithRunner(r.run)
	ctx := context.Background()
	_ = c.Switch(ctx, 2)
	_, _ = c.AddCurrent(ctx, "Home")
	_ = c.Rename(ctx, 3, "New name")
	_ = c.Remove(ctx, 3)
	want := [][]string{
		{"switch", "--json", "2"},
		{"add", "--json", "--nickname", "Home"},
		{"rename", "--json", "3", "New name"},
		{"remove", "--json", "3"},
	}
	if !reflect.DeepEqual(r.args, want) {
		t.Fatalf("args %v", r.args)
	}
}

func TestAddSignedInSendsCodeOnStdin(t *testing.T) {
	r := &recorder{out: `{"account":{"number":2,"email":"b@x.com"},"wasDuplicate":false}`}
	c := NewWithRunner(r.run)
	res, err := c.AddSignedIn(context.Background(), &SignIn{State: "st", Verifier: "ver"}, "abc#st", "Work", "")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(r.args[0], []string{"add-oauth-code", "--json"}) {
		t.Fatalf("args %v", r.args[0])
	}
	if r.stdin[0] != `{"code":"abc#st","expectedEmail":"","nickname":"Work","state":"st","verifier":"ver"}` {
		t.Fatalf("stdin %s", r.stdin[0])
	}
	if res.Account.Number != 2 {
		t.Fatalf("result %+v", res)
	}
}

func TestNeedsLoginCountsOnlyAuthFailures(t *testing.T) {
	r := &recorder{out: `{"results":[
		{"accountNum":1,"isActive":true,"checks":[{"name":"usage_reachable","passed":false,"detail":"401"}]},
		{"accountNum":2,"checks":[{"name":"token_refresh","passed":false,"detail":"oauth refresh 400: {\"error\":\"invalid_grant\"}"}]},
		{"accountNum":3,"checks":[{"name":"token_refresh","passed":false,"detail":"dial tcp: no such host"}]},
		{"accountNum":4,"checks":[{"name":"credentials_present","passed":false,"detail":"empty"}]},
		{"accountNum":5,"checks":[{"name":"usage_reachable","skipped":true,"detail":"rate limited"}]}
	],"total":5}`}
	dead, err := NewWithRunner(r.run).NeedsLogin(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(dead, map[int]bool{2: true, 4: true}) {
		t.Fatalf("dead %v", dead)
	}
}

func TestCswErrorUsesLastStderrLine(t *testing.T) {
	err := cswError("warming up\nerror: account 4 credentials need login again\n", errors.New("exit status 1"))
	if err.Error() != "account 4 credentials need login again" {
		t.Fatalf("err %q", err)
	}
	if cswError("", errors.New("exit status 1")).Error() != "exit status 1" {
		t.Fatal("empty stderr should keep the exit error")
	}
}
