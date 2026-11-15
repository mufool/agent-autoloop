#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
用法：./local/deploy/bootstrap.sh [--check | --install-config]

  --check           只检查前置条件、配置格式和文件权限（默认）
  --install-config  备份并安装 rules.local.json 与 workbuddy-command.settings.json

不会生成密钥，不会修改 config.json，不会安装 LaunchAgent 或系统服务。
EOF
}

fail() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

mode=--check
case "${1:-}" in
  "") ;;
  --check) mode=--check ;;
  --install-config) mode=--install-config ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) fail "不认识的参数：$1" ;;
esac

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
deploy_root=$repo_root/local/deploy
autoloop_home=${AGENT_AUTOLOOP_HOME:-"$HOME/.agent-autoloop"}
workspace_root=${WORKSPACE_ROOT:-"$HOME/Documents/workspace"}
url_skill_source=$workspace_root/.codebuddy/skills/workspace-url
url_skill_link=$HOME/.codebuddy/skills/workspace-url
review_skill_source=$workspace_root/.codebuddy/skills/workspace-url-failure-review
review_skill_link=$HOME/.codebuddy/skills/workspace-url-failure-review
workbuddy_node=${WORKBUDDY_NODE:-"$HOME/.workbuddy/binaries/node/versions/22.22.2-6/bin/node"}
workbuddy_cli=${WORKBUDDY_CLI:-"$(dirname "$workbuddy_node")/codebuddy"}

command -v node >/dev/null 2>&1 || fail "缺少 node"
command -v uv >/dev/null 2>&1 || fail "缺少 uv"
command -v git >/dev/null 2>&1 || fail "缺少 git"
command -v curl >/dev/null 2>&1 || fail "缺少 curl"
node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 24 ? 0 : 1)' ||
  fail "中台需要 Node.js 24 或更新，当前是 $(node --version)"
[ -x "$workbuddy_node" ] || fail "找不到 WorkBuddy Node 22：$workbuddy_node"
[ -x "$workbuddy_cli" ] || fail "找不到 WorkBuddy CLI：$workbuddy_cli"
[ -d "$workspace_root" ] || fail "找不到 workspace：$workspace_root"
[ -f "$url_skill_source/SKILL.md" ] || fail "找不到 workspace-url Skill：$url_skill_source"
[ -f "$review_skill_source/SKILL.md" ] ||
  fail "找不到 workspace-url-failure-review Skill：$review_skill_source"

node -e 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"))' \
  "$deploy_root/rules.local.json" || fail "rules.local.json 不是合法 JSON"
node -e 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"))' \
  "$deploy_root/workbuddy-command.settings.json" || fail "workbuddy-command.settings.json 不是合法 JSON"

node --disable-warning=ExperimentalWarning "$repo_root/bin/agent-autoloop.ts" check \
  "$deploy_root/rules.local.json" >/dev/null || fail "rules.local.json 未通过 agent-autoloop check"

private_file() {
  file=$1
  [ -f "$file" ] || fail "缺少 $file；先按 local/deploy/env.example 创建并填值"
  bits=$(stat -f '%Lp' "$file")
  [ "$bits" = 600 ] || fail "$file 的权限是 $bits，应为 600"
}

install_config() {
  source_file=$1
  target_file=$2
  if [ -f "$target_file" ]; then
    backup="$target_file.bak-$(date +%Y%m%d%H%M%S)"
    cp -p "$target_file" "$backup"
    printf '已备份：%s\n' "$backup"
  fi
  temporary=$(mktemp "$target_file.XXXXXX")
  cp "$source_file" "$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$target_file"
  printf '已安装：%s\n' "$target_file"
}

ensure_skill_link() {
  source_directory=$1
  link_path=$2
  if [ -L "$link_path" ]; then
    linked=$(readlink "$link_path")
    [ "$linked" = "$source_directory" ] ||
      fail "$link_path 已指向 $linked，不自动覆盖"
  elif [ -e "$link_path" ]; then
    fail "$link_path 已存在且不是符号链接，不自动覆盖"
  else
    ln -s "$source_directory" "$link_path"
    printf '已链接：%s -> %s\n' "$link_path" "$source_directory"
  fi
}

if [ "$mode" = --install-config ]; then
  mkdir -p "$autoloop_home" \
    "$workspace_root/content/.automation/url" \
    "$workspace_root/content/.automation/url-failure-review" \
    "$(dirname "$url_skill_link")"
  chmod 700 "$autoloop_home"
  install_config "$deploy_root/rules.local.json" "$autoloop_home/rules.json"
  install_config "$deploy_root/workbuddy-command.settings.json" \
    "$autoloop_home/workbuddy-command.settings.json"
  ensure_skill_link "$url_skill_source" "$url_skill_link"
  ensure_skill_link "$review_skill_source" "$review_skill_link"
fi

private_file "$autoloop_home/workspace.env"
private_file "$autoloop_home/agent.env"

if [ -L "$url_skill_link" ]; then
  [ "$(readlink "$url_skill_link")" = "$url_skill_source" ] ||
    fail "$url_skill_link 指向了错误的位置"
elif [ -e "$url_skill_link" ]; then
  fail "$url_skill_link 已存在且不是符号链接"
else
  fail "workspace-url Skill 尚未链接；运行 --install-config 创建"
fi

if [ -L "$review_skill_link" ]; then
  [ "$(readlink "$review_skill_link")" = "$review_skill_source" ] ||
    fail "$review_skill_link 指向了错误的位置"
elif [ -e "$review_skill_link" ]; then
  fail "$review_skill_link 已存在且不是符号链接"
else
  fail "workspace-url-failure-review Skill 尚未链接；运行 --install-config 创建"
fi

[ -f "$autoloop_home/rules.json" ] || fail "缺少 $autoloop_home/rules.json"
[ -f "$autoloop_home/workbuddy-command.settings.json" ] ||
  fail "缺少 $autoloop_home/workbuddy-command.settings.json"
[ -d "$workspace_root/content/.automation/url" ] ||
  fail "缺少共享暂存目录；运行 --install-config 创建"
[ -d "$workspace_root/content/.automation/url-failure-review" ] ||
  fail "缺少失败巡检工作目录；运行 --install-config 创建"

printf '本机部署检查通过。\n'
printf '启动：cd %s && node --disable-warning=ExperimentalWarning bin/agent-autoloop.ts up\n' "$repo_root"
