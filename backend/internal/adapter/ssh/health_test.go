package ssh

import "testing"

func TestParseDiskUsedPct(t *testing.T) {
	cases := []struct {
		name   string
		in     string
		want   int
		wantOK bool
	}{
		{
			name: "linux df -P",
			in: "Filesystem     1024-blocks     Used Available Capacity Mounted on\n" +
				"/dev/sda1         41251136  8765432  30384704      23% /",
			want: 23, wantOK: true,
		},
		{
			name: "macos df -P",
			in: "Filesystem   512-blocks       Used Available Capacity  Mounted on\n" +
				"/dev/disk3s5 1942700360 1234567890 700000000      63%   /",
			want: 63, wantOK: true,
		},
		{
			name: "nearly full",
			in: "Filesystem 1024-blocks Used Available Capacity Mounted on\n" +
				"/dev/root  100 92 8 92% /",
			want: 92, wantOK: true,
		},
		{
			name: "wrapped filesystem column",
			in: "Filesystem 1024-blocks Used Available Capacity Mounted on\n" +
				"/dev/mapper/really-long-name\n" +
				"           100 5 95 5% /data",
			want: 5, wantOK: true,
		},
		{name: "empty", in: "", want: 0, wantOK: false},
		{name: "header only", in: "Filesystem 1024-blocks Used Available Capacity Mounted on", want: 0, wantOK: false},
		{name: "garbage", in: "df: /nope: No such file or directory", want: 0, wantOK: false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := parseDiskUsedPct(c.in)
			if ok != c.wantOK || got != c.want {
				t.Fatalf("parseDiskUsedPct = (%d,%v), want (%d,%v)", got, ok, c.want, c.wantOK)
			}
		})
	}
}
