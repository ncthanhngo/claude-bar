package ssh

import "testing"

func TestParseDiskMounts(t *testing.T) {
	in := "Filesystem 1024-blocks Used Available Capacity Mounted on\n" +
		"/dev/sda1  100 23 77 23% /\n" +
		"/dev/sdb1  100 91 9  91% /data\n" +
		"/dev/sdc1  100 40 60 40% /var"
	mounts := parseDiskMounts(in)
	if len(mounts) != 3 {
		t.Fatalf("got %d mounts, want 3: %+v", len(mounts), mounts)
	}
	if mounts[1].Path != "/data" || mounts[1].UsedPct != 91 {
		t.Fatalf("mounts[1] = %+v, want {/data 91}", mounts[1])
	}
	worst, ok := worstMount(mounts)
	if !ok || worst.UsedPct != 91 || worst.Path != "/data" {
		t.Fatalf("worst = %+v (%v), want {/data 91}", worst, ok)
	}
	if len(parseDiskMounts("")) != 0 {
		t.Fatal("empty df → no mounts")
	}
	if _, ok := worstMount(nil); ok {
		t.Fatal("no mounts → worstMount ok=false")
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

func TestParseMem(t *testing.T) {
	free := "              total        used        free      shared  buff/cache   available\n" +
		"Mem:    8000000000  6000000000  1000000000    10000  1000000000  1900000000\n" +
		"Swap:   2000000000           0  2000000000"
	if used, total, ok := parseMem(free); !ok || used != 75 || total != 8000000000 {
		t.Fatalf("mem = (%d,%d,%v), want (75,8000000000,true)", used, total, ok)
	}
	if _, _, ok := parseMem("no mem here"); ok {
		t.Fatal("missing Mem: line should fail")
	}
}

func TestParseCPU(t *testing.T) {
	model, cores := parseCPU("Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz\n8")
	if model != "Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz" || cores != 8 {
		t.Fatalf("cpu = (%q,%d), want (Xeon…, 8)", model, cores)
	}
	// Order-tolerant + empty model line (ARM) still yields the core count.
	if m, c := parseCPU("\n4"); m != "" || c != 4 {
		t.Fatalf("cpu = (%q,%d), want (\"\",4)", m, c)
	}
}

func TestParseServices(t *testing.T) {
	got := parseServices("nginx|active\npostgresql|inactive\ndocker:api|running\ndocker:db|missing")
	want := []ServiceStatus{
		{Name: "nginx", State: "active", Active: true},
		{Name: "postgresql", State: "inactive", Active: false},
		{Name: "docker:api", State: "running", Active: true},
		{Name: "docker:db", State: "missing", Active: false},
	}
	if len(got) != len(want) {
		t.Fatalf("got %d services, want %d (%+v)", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("service %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}

func TestParseServiceList(t *testing.T) {
	got := parseServiceList(" nginx, postgresql  docker:api\n")
	if len(got) != 3 || got[0] != "nginx" || got[2] != "docker:api" {
		t.Fatalf("parseServiceList = %v", got)
	}
	if len(parseServiceList("")) != 0 {
		t.Error("empty string should yield no services")
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
