package ssh

import "testing"

func TestClassifyAllowlistLow(t *testing.T) {
	for _, c := range []string{"uptime", "whoami", "hostname", "date", "df -h", "free -m"} {
		if got := ClassifyCmd(c); got != RiskLow {
			t.Errorf("%q → %v, want Low", c, got)
		}
	}
}

func TestClassifyMetacharForcesDestructive(t *testing.T) {
	// Red-Team Finding 6 bypass attempts.
	bypasses := []string{
		"uptime; rm -rf /",
		"uptime && rm /etc",
		"echo a | tail -f /etc/passwd",
		"`whoami`",
		"$(rm -rf /)",
		"date > /tmp/out",
		"cat < /etc/shadow",
		"echo " + "ZGFuZ2Vyb3VzcGF5bG9hZGhlcmU=" + "=", // 16+ char base64-shaped chunk
		"sudo systemctl restart\nrm /etc", // newline injection
	}
	for _, c := range bypasses {
		if got := ClassifyCmd(c); got != RiskDestructive {
			t.Errorf("bypass %q → %v, want Destructive", c, got)
		}
	}
}

func TestClassifyReadFamiliesAreLow(t *testing.T) {
	for _, c := range []string{
		"tail -n 100 /var/log/nginx/error.log",
		"cat /etc/hostname",
		"ls -la /opt",
		"grep -i error /var/log/syslog",
		"ps aux",
		"journalctl -u nginx -n 50",
		"docker ps",
		"kubectl get pods",
		"systemctl status nginx",
	} {
		if got := ClassifyCmd(c); got != RiskLow {
			t.Errorf("%q → %v, want Low", c, got)
		}
	}
}

func TestClassifyMediumFamilies(t *testing.T) {
	for _, c := range []string{
		"systemctl restart nginx",
		"docker restart web",
		"kubectl apply -f manifest.yaml",
		"git pull origin main",
	} {
		if got := ClassifyCmd(c); got != RiskMedium {
			t.Errorf("%q → %v, want Medium", c, got)
		}
	}
}

func TestClassifyDestructiveFamilies(t *testing.T) {
	for _, c := range []string{
		"rm -rf /tmp/foo",
		"dd if=/dev/zero of=/dev/sda",
		"mkfs.ext4 /dev/sdb",
		"shutdown now",
		"reboot",
		"kubectl delete pod foo",
		"systemctl stop nginx",
	} {
		if got := ClassifyCmd(c); got != RiskDestructive {
			t.Errorf("%q → %v, want Destructive", c, got)
		}
	}
}

func TestClassifySudoBumpsLevel(t *testing.T) {
	cases := map[string]Risk{
		"sudo uptime":            RiskMedium,
		"sudo systemctl restart nginx": RiskDestructive,
		"sudo rm /tmp/foo":       RiskDestructive,
	}
	for in, want := range cases {
		if got := ClassifyCmd(in); got != want {
			t.Errorf("%q → %v, want %v", in, got, want)
		}
	}
}

func TestClassifyUnknownIsMedium(t *testing.T) {
	for _, c := range []string{
		"npm install",
		"./deploy.sh",
		"python3 migrate.py",
	} {
		if got := ClassifyCmd(c); got != RiskMedium {
			t.Errorf("%q → %v, want Medium", c, got)
		}
	}
}
