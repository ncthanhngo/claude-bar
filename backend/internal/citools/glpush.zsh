# ci-watch & các CLI cá nhân
[[ ":$PATH:" == *":$HOME/.local/bin:"* ]] || export PATH="$HOME/.local/bin:$PATH"

# ─── glpush: push commit hiện tại + tự theo dõi CI (GitLab/GitHub) nền → notify ───
# Tổng quát mọi dự án: auto-detect provider/host/project từ `origin`. Push thẳng
# fetch-URL (tránh dual-push silent-fail), rồi chạy ci-watch nền → macOS notify.
# Cần: ci-watch trong PATH; glab auth cho host GitLab tương ứng / gh auth cho GitHub.
glpush() {
	emulate -L zsh
	setopt pipefail localoptions
	local url branch sha provider host project rest path logf
	git rev-parse --is-inside-work-tree &>/dev/null || { echo "✗ không phải git repo"; return 1; }
	url=$(git remote get-url origin 2>/dev/null) || { echo "✗ không có remote origin"; return 1; }
	branch=$(git rev-parse --abbrev-ref HEAD)

	# Parse host + path từ các dạng URL: ssh://git@host:port/path · git@host:path · https://host/path
	case "$url" in
		ssh://*)    rest="${url#ssh://}"; rest="${rest#*@}"; host="${rest%%[:/]*}"; path="${rest#*/}";;
		https://*)  rest="${url#https://}"; rest="${rest#*@}"; host="${rest%%/*}";   path="${rest#*/}";;
		*@*:*)      rest="${url#*@}";       host="${rest%%:*}";  path="${rest#*:}";;
		*) echo "✗ không parse được URL origin: $url"; return 1;;
	esac
	host="${host%%:*}"; project="${path%.git}"
	case "$host" in
		*github*) provider=github;;
		*gitlab*) provider=gitlab;;
		*) echo "✗ host không nhận diện (chỉ GitLab/GitHub): $host"; return 1;;
	esac
	command -v ci-watch &>/dev/null || { echo "✗ thiếu ci-watch trong PATH"; return 1; }

	echo "→ push $project ($branch) tới $provider:$host…"
	git push "$url" "HEAD:$branch" || { echo "✗ push thất bại"; return 1; }
	sha=$(git rev-parse HEAD)
	logf="/tmp/glpush-${host}-${project//\//-}.log"

	echo "→ theo dõi CI nền (notify khi xong). Log: $logf"
	(
		ci-watch --provider "$provider" --host "$host" --project "$project" \
		         --ref "$branch" --sha "$sha" --poll 20 --max 1500 --tail 40 >"$logf" 2>&1
		local rc=$? title body
		if (( rc == 0 )); then
			title="✅ CI xanh: $project"; body="$branch @ ${sha:0:8}"
		else
			title="❌ CI FAIL: $project"; body="${sha:0:8} — xem $logf, rồi mở claude: 'fix CI'"
		fi
		osascript -e "display notification \"$body\" with title \"$title\"" 2>/dev/null
	) &!
}
