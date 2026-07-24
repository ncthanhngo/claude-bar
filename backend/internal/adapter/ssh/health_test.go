package ssh

import "testing"

func TestParseWorstDisk(t *testing.T) {
	cases := []struct {
		name    string
		in      string
		wantPct int
		wantOK  bool
	}{
		{
			name: "linux single mount",
			in: "Filesystem     1024-blocks     Used Available Capacity Mounted on\n" +
				"/dev/sda1         41251136  8765432  30384704      23% /",
			wantPct: 23, wantOK: true,
		},
		{
			name: "several mounts → worst",
			in: "Filesystem 1024-blocks Used Available Capacity Mounted on\n" +
				"/dev/sda1  100 23 77 23% /\n" +
				"/dev/sdb1  100 91 9  91% /data\n" +
				"/dev/sdc1  100 40 60 40% /var",
			wantPct: 91, wantOK: true,
		},
		{name: "empty", in: "", wantPct: -1, wantOK: false},
		{name: "header only", in: "Filesystem 1024-blocks Used Available Capacity Mounted on", wantPct: -1, wantOK: false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			pct, _, ok := parseWorstDisk(c.in)
			if ok != c.wantOK || (ok && pct != c.wantPct) {
				t.Fatalf("parseWorstDisk = (%d,%v), want (%d,%v)", pct, ok, c.wantPct, c.wantOK)
			}
		})
	}
}

func TestParseLoad1(t *testing.T) {
	if v, ok := parseLoad1("0.52 0.48 0.44 2/318 9012"); !ok || v != 0.52 {
		t.Fatalf("load1 = (%v,%v), want (0.52,true)", v, ok)
	}
	if _, ok := parseLoad1(""); ok {
		t.Fatal("empty loadavg should fail")
	}
}

func TestParseMemUsedPct(t *testing.T) {
	free := "              total        used        free      shared  buff/cache   available\n" +
		"Mem:    8000000000  6000000000  1000000000    10000  1000000000  1900000000\n" +
		"Swap:   2000000000           0  2000000000"
	if v, ok := parseMemUsedPct(free); !ok || v != 75 {
		t.Fatalf("mem = (%d,%v), want (75,true)", v, ok)
	}
	if _, ok := parseMemUsedPct("no mem here"); ok {
		t.Fatal("missing Mem: line should fail")
	}
}

func TestParseUptimeSecs(t *testing.T) {
	if v, ok := parseUptimeSecs("123456.78 90123.4"); !ok || v != 123456 {
		t.Fatalf("uptime = (%d,%v), want (123456,true)", v, ok)
	}
}

func TestParseDiskPaths(t *testing.T) {
	got := parseDiskPaths("/, /data ,/var")
	want := []string{"/", "/data", "/var"}
	if len(got) != len(want) {
		t.Fatalf("paths = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("paths[%d] = %q, want %q", i, got[i], want[i])
		}
	}
	if p := parseDiskPaths(""); len(p) != 1 || p[0] != "/" {
		t.Fatalf("empty → %v, want [/]", p)
	}
}

func TestHostKeyChanged(t *testing.T) {
	if !hostKeyChanged("@@@@@@\nWARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\n") {
		t.Fatal("should detect host-key change")
	}
	if hostKeyChanged("Permission denied (publickey).") {
		t.Fatal("normal auth error is not a host-key change")
	}
}
