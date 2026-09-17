#!/bin/bash
# ==============================================================================
# libwrt.sh —— ZN_M2 (IPQ6000 / qualcommax-ipq60xx) OpenWrt 6.12 固件自定义脚本
#
# 设计原则：
#   1. 任何一步失败都必须让 CI 失败（set -euo pipefail），杜绝静默失败
#   2. 默认信任 Passwall 上游已联调验证的版本，不自动改版本
#      （避免 /releases/latest 跳过 pre-release 导致的降级，以及哈希污染）
#   3. 设 TRACK_LATEST=1 时才跟踪上游最新 tag，且版本号与 PKG_HASH 原子更新
#   4. 显式消除 Passwall 克隆包与 immortalwrt feed 的重复来源
#   5. 只有 .config 中真正启用的插件才克隆，保证"配置即真相"
#
# 环境变量：
#   TRACK_LATEST=1   跟踪上游最新 release（含 pre-release）并原子更新版本+哈希
#   PW_REF=<ref>     固定 passwall 仓库的分支/tag/commit，默认 main
#   GITHUB_TOKEN     建议注入，避免 GitHub API 匿名 60 次/小时限流
# ==============================================================================
set -euo pipefail

PW_REF="${PW_REF:-main}"
TRACK_LATEST="${TRACK_LATEST:-0}"

# 路径约定：
#   openwrt-passwall         根/luci-app-passwall/        （上游嵌套）
#   openwrt-passwall2        根/luci-app-passwall2/       （上游嵌套）
#   openwrt-passwall-packages 根/<component>/             （上游平铺）
# 解决方案：用 tmp 克隆 + mv 拍平，让 OpenWrt 与下游重复检测都看到扁平结构。
PKG_LUCI_DIR="package/luci-app-passwall"               # 拍平后的最终位置（=第一层）
PKG_LUCI_MK="package/luci-app-passwall/Makefile"
PKG_LUCI_TMP="package/.luci-app-passwall.tmp"          # 临时克隆位置（不进入扫描）
PKG_LUCI2_DIR="package/luci-app-passwall2"
PKG_LUCI2_MK="package/luci-app-passwall2/Makefile"
PKG_LUCI2_TMP="package/.luci-app-passwall2.tmp"
PKG_CORE="package/openwrt-passwall-packages"           # 平铺结构
PKG_CORE_DEFAULT_BRANCH="xray-core"                    # 用于检测克隆是否完整

log()  { echo "::notice::$*"; }
warn() { echo "::warning::$*"; }
die()  { echo "::error::$*"; exit 1; }

# 必须在 OpenWrt 源码根目录运行
[ -f scripts/feeds ] || die "请在 OpenWrt 源码根目录运行本脚本（未找到 scripts/feeds）"
[ -f .config ]       || die "未找到 .config，请先拷贝编译配置"

# 每次重启都重新克隆（防止上一次半截残留）
[ -d "$PKG_LUCI_DIR" ]   && rm -rf "$PKG_LUCI_DIR"
[ -d "$PKG_LUCI_TMP" ]   && rm -rf "$PKG_LUCI_TMP"
[ -d "$PKG_LUCI2_DIR" ]  && rm -rf "$PKG_LUCI2_DIR"
[ -d "$PKG_LUCI2_TMP" ]  && rm -rf "$PKG_LUCI2_TMP"
[ -d "$PKG_CORE" ]       && rm -rf "$PKG_CORE"

# ------------------------------------------------------------------------------
# 工具函数
# ------------------------------------------------------------------------------

# 判断 .config 中某包是否启用
config_enabled() { grep -qx "CONFIG_PACKAGE_$1=y" .config; }

# 读取 Makefile 中当前的 PKG_VERSION
pkg_version() {
  local mk="$1"
  awk -F':=' '/^PKG_VERSION[[:space:]]*:=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$mk"
}

# 写入 GitHub Actions 环境变量（本地运行时安全跳过）
emit_env() {
  [ -n "${GITHUB_ENV:-}" ] && echo "$1=$2" >> "$GITHUB_ENV"
  return 0
}

# 取最新 release tag（含 pre-release，跳过 draft）。失败返回 1。
latest_release_tag() {
  local repo="$1" out
  local -a hdrs=( -H "Accept: application/vnd.github+json" )
  [ -n "${GITHUB_TOKEN:-}" ] && hdrs+=( -H "Authorization: Bearer ${GITHUB_TOKEN}" )

  # /releases?per_page=N 按创建时间倒序返回，且包含 pre-release
  # （/releases/latest 会跳过 pre-release，Xray-core 因此会被降级到 26.3.27）
  # 再用 test() 只保留"纯数字点分"版本号，排除 1.15.0-alpha.2 这类 alpha/beta/rc
  out=$(curl -fsSL --retry 3 --retry-delay 3 --max-time 30 "${hdrs[@]}" \
        "https://api.github.com/repos/${repo}/releases?per_page=50" \
      | jq -r '[ .[] | select(.draft | not) | .tag_name
                 | select(test("^v?[0-9]+(\\.[0-9]+){1,3}$")) ] | first // empty') || return 1

  out="${out#v}"
  # 二次校验：拦截 "null" / "API rate limit exceeded" 等噪声
  [[ "$out" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || return 1
  printf '%s' "$out"
}

# 计算 codeload 源码包 sha256。失败返回 1。
source_tarball_hash() {
  local repo="$1" ver="$2" tmp
  tmp="$(mktemp)"
  # -f：HTTP 4xx/5xx 直接非零退出，杜绝把 404 错误页（14 字节）当成源码包
  if ! curl -fsSL --retry 3 --retry-delay 3 --max-time 300 \
        -o "$tmp" "https://codeload.github.com/${repo}/tar.gz/v${ver}"; then
    rm -f "$tmp"; return 1
  fi
  # 二次校验：源码包体积不可能小于 10KB
  if [ "$(wc -c < "$tmp")" -lt 10240 ]; then
    rm -f "$tmp"; return 1
  fi
  sha256sum "$tmp" | awk '{print $1}'
  rm -f "$tmp"
}

# 原子更新包的版本与哈希。任何异常都保持原版本，绝不写 PKG_HASH:=skip。
update_pkg() {
  local pkg="$1" repo="$2" ver="$3" mk cur hash
  mk="${PKG_CORE}/${pkg}/Makefile"
  [ -f "$mk" ] || { warn "未找到 ${mk}，跳过 ${pkg}"; return 0; }

  cur="$(pkg_version "$mk")"
  [ "$cur" = "$ver" ] && { log "${pkg}: 已是 ${ver}"; return 0; }

  if ! hash="$(source_tarball_hash "$repo" "$ver")"; then
    warn "${pkg}: 无法获取 v${ver} 源码包，保持原版本 ${cur}"
    return 0
  fi

  # 版本号与哈希必须同时替换
  sed -i -e "s/^PKG_VERSION[[:space:]]*:=.*/PKG_VERSION:=${ver}/" \
         -e "s/^PKG_HASH[[:space:]]*:=.*/PKG_HASH:=${hash}/" "$mk"

  grep -qx "PKG_VERSION:=${ver}" "$mk" || die "${pkg}: 版本写入失败"
  log "${pkg}: ${cur} -> ${ver}"
}

# 稀疏克隆（补齐原脚本中缺失的定义）
git_sparse_clone() {
  local branch="$1" url="$2" dir="$3"; shift 3
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$url"
  git -C "$dir" config core.sparseCheckout true
  printf '%s\n' "$@" > "$dir/.git/info/sparse-checkout"
  git -C "$dir" fetch -q --depth 1 origin "$branch"
  git -C "$dir" checkout -q "$branch"
}

# ------------------------------------------------------------------------------
# 1. 消除重复来源：仅当本脚本后续会克隆替代包时，才删 feed 侧的副本
#    （immortalwrt@openwrt-25.12 的 sing-box 仍为 1.12.25，落后两个小版本）
#    注意：uhttpd 等核心 feed 不动；只删本脚本自带替代品的那些包。
# ------------------------------------------------------------------------------
log "清理 feeds 中与 Passwall 重复的包来源（仅限有替代品的包）..."

# Passwall 主仓 + 组件仓自带替代品的删 feed
rm -rf feeds/packages/net/{xray-core,sing-box,xray-plugin,chinadns-ng,dns2socks,geoview,ipt2socks,microsocks,naiveproxy,shadow-tls,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,v2ray-geodata,v2ray-plugin,hysteria}

# luci-app-passwall 由本脚本的步骤 2 克隆（拍平后写入 package/luci-app-passwall/Makefile）
rm -rf feeds/luci/applications/luci-app-passwall

# 仅当用户启用 passwall2 时才动 luci-app-passwall2（避免误删未启用的可用包）
if config_enabled luci-app-passwall2; then
  rm -rf feeds/luci/applications/luci-app-passwall2
fi

# ------------------------------------------------------------------------------
# 2. 克隆 Passwall（主仓库 + 依赖组件集合）
# ------------------------------------------------------------------------------
log "克隆 Passwall 组件（ref=${PW_REF}）..."
git clone --depth 1 -b "$PW_REF" https://github.com/Openwrt-Passwall/openwrt-passwall-packages "$PKG_CORE" \
  || die "克隆 $PKG_CORE 失败"
[ -d "${PKG_CORE}/${PKG_CORE_DEFAULT_BRANCH}" ] \
  || die "$PKG_CORE/${PKG_CORE_DEFAULT_BRANCH} 不存在，克隆可能不完整（请检查分支 ${PW_REF} 是否存在）"

# 克隆到临时目录（以 . 开头避免被 OpenWrt 扫描到），再 mv 内层子目录到最终位置——拍平嵌套结构
git clone --depth 1 -b "$PW_REF" https://github.com/Openwrt-Passwall/openwrt-passwall "$PKG_LUCI_TMP" \
  || die "克隆 $PKG_LUCI_TMP 失败"
[ -d "${PKG_LUCI_TMP}/luci-app-passwall" ] \
  || die "未找到 ${PKG_LUCI_TMP}/luci-app-passwall（上游 openwrt-passwall 目录结构可能又改了，请到 https://github.com/Openwrt-Passwall/openwrt-passwall 核对）"
mv "${PKG_LUCI_TMP}/luci-app-passwall" "$PKG_LUCI_DIR" || die "mv 失败"
rm -rf "$PKG_LUCI_TMP"
[ -f "$PKG_LUCI_MK" ] \
  || die "未找到 $PKG_LUCI_MK（拍平后 Makefile 缺失，请检查上游包结构）"

# 只有配置里启用了 passwall2 才克隆
if config_enabled luci-app-passwall2; then
  git clone --depth 1 -b "$PW_REF" https://github.com/Openwrt-Passwall/openwrt-passwall2 "$PKG_LUCI2_TMP" \
    || die "克隆 $PKG_LUCI2_TMP 失败"
  [ -d "${PKG_LUCI2_TMP}/luci-app-passwall2" ] \
    || die "未找到 ${PKG_LUCI2_TMP}/luci-app-passwall2（上游 openwrt-passwall2 目录结构可能又改了）"
  mv "${PKG_LUCI2_TMP}/luci-app-passwall2" "$PKG_LUCI2_DIR" || die "mv 失败"
  rm -rf "$PKG_LUCI2_TMP"
  [ -f "$PKG_LUCI2_MK" ] \
    || die "未找到 $PKG_LUCI2_MK"
fi

# ------------------------------------------------------------------------------
# 3. 可选插件：仅当 .config 中真正启用时才克隆
#    注意：克隆前要删 feed 侧的同名包，否则 immortalwrt 默认版本会被优先选中
# ------------------------------------------------------------------------------
if config_enabled luci-app-openclash; then
  rm -rf feeds/luci/applications/luci-app-openclash
  log "克隆 OpenClash..."
  git_sparse_clone main https://github.com/vernesong/OpenClash luci-app-openclash
fi

if config_enabled luci-app-smartdns || config_enabled smartdns; then
  rm -rf feeds/packages/net/smartdns feeds/luci/applications/luci-app-smartdns
  log "克隆 SmartDNS..."
  git clone --depth 1 -b lede https://github.com/pymumu/luci-app-smartdns package/luci-app-smartdns
  git clone --depth 1 https://github.com/pymumu/openwrt-smartdns package/smartdns
fi

# ------------------------------------------------------------------------------
# 4. 版本处理
#    默认：信任上游，只读不写（推荐）
#    TRACK_LATEST=1：跟踪最新 release，版本号与哈希原子更新
# ------------------------------------------------------------------------------
if [ "$TRACK_LATEST" = "1" ]; then
  log "TRACK_LATEST=1，跟踪上游最新版本..."
  for spec in "xray-core:XTLS/Xray-core" "sing-box:SagerNet/sing-box"; do
    pkg="${spec%%:*}"; repo="${spec#*:}"
    if ver="$(latest_release_tag "$repo")"; then
      update_pkg "$pkg" "$repo" "$ver"
    else
      warn "${pkg}: 获取最新版本号失败，保持 Passwall 上游版本"
    fi
  done
else
  log "使用 Passwall 上游已验证版本（不自动改写）。如需跟踪最新请设 TRACK_LATEST=1"
fi

# ------------------------------------------------------------------------------
# 4b. Go 工具链兼容性守门（关键：这是 2026-09 实测会真实编译失败的点）
#
# 背景（均已实测确认）：
#   - immortalwrt/packages@openwrt-25.12 的 lang/golang 目录只有 golang1.26，
#     **没有 golang1.27** → 本分支无法通过设置切换 Go 版本
#   - golang-package.mk 里硬编码了 GOTOOLCHAIN=local → 用 env 覆盖 GOTOOLCHAIN=auto 无效
#   - Xray-core 自 26.9.8 起 go.mod 要求 go >= 1.27，直接用必然失败：
#       go: ../../go.mod requires go >= 1.27 (running go 1.26.8; GOTOOLCHAIN=local)
#       ERROR: package/openwrt-passwall-packages/xray-core failed to build.
#   因此这里在编译前主动把 Xray 回退到"最后一个 go.mod 要求 <= 1.26"的版本。
#
# 实测分界（读取各 tag 的 go.mod）：
#     26.9.9 / 26.9.8  -> go >= 1.27   ✗ 编译失败
#     26.7.28 / 26.7.11 / 26.6.27 ... -> go >= 1.26   ✓
# ------------------------------------------------------------------------------
GO_TOOLCHAIN_MAX="1.26"        # feed 能提供的 Go 上限（实测只有 golang1.26）
XRAY_GO_SAFE_VER="26.7.28"     # 最后一个兼容 Go 1.26 的版本
XRAY_GO_SAFE_HASH="a9afe86349c7bd3e6cae60125e62a5ada09d102e1a2760623e77c24a84dbfb46"
# ↑ 该哈希为 codeload tarball 的 sha256，已实测校验：
#   curl -sL https://codeload.github.com/XTLS/Xray-core/tar.gz/v26.7.28 | sha256sum
#   且解包后 go.mod 确认为 "go 1.26"。

# 取 go.mod 的 go 指令版本。失败返回 1。
# 实现要点（两个坑都避开）：
#   1. 不能用 `curl ... | awk '{print; exit}'`：awk 提前 exit 会让 curl 收到 EPIPE(错误 23)，
#      pipefail 下整个管道判失败 → 明明成功却返回失败。
#   2. 不用 mktemp 落盘：某些环境（MSYS/受限 TMPDIR）curl -o 到 mktemp 路径同样报错误 23。
#   改为：先用命令替换完整取回内容，再用 bash 内建 while-read 解析（无管道、无临时文件）。
go_mod_requirement() {
  local repo="$1" tag="$2" out go_ver="" k v
  out=$(curl -fsSL --retry 3 --retry-delay 3 --max-time 30 \
        "https://raw.githubusercontent.com/${repo}/${tag}/go.mod") || return 1
  while read -r k v _; do
    [ "$k" = "go" ] || continue
    go_ver="${v//$'\r'/}"     # 去掉可能的 CR
    break
  done <<< "$out"
  [[ "$go_ver" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || return 1
  printf '%s' "$go_ver"
}

# Go 版本比较：$1 > $2 ?
# 先归一化到 major.minor 再比：go.mod 可能写 "go 1.25.5" 这类补丁级指令，
# 而工具链是 1.26.8，直接按三段比会把"同系列更新"误判成"不兼容"而错误回退。
version_gt() {
  local a b
  a="$(awk -F. '{print $1"."$2}' <<< "$1")"
  b="$(awk -F. '{print $1"."$2}' <<< "$2")"
  [ "$a" != "$b" ] || return 1
  [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)" = "$b" ]
}

log "检查 Go 工具链兼容性（feed 上限 go ${GO_TOOLCHAIN_MAX}）..."

# --- xray-core：有预设兼容版本，超限自动回退 ---
XRAY_MK="${PKG_CORE}/xray-core/Makefile"
XRAY_CUR="$(pkg_version "$XRAY_MK")"
[ -n "$XRAY_CUR" ] || die "未能读取 xray-core 版本"
XRAY_NEED="$(go_mod_requirement "XTLS/Xray-core" "v${XRAY_CUR}" || true)"

if [ -z "$XRAY_NEED" ]; then
  warn "无法读取 Xray v${XRAY_CUR} 的 go.mod 要求（网络/限流），保守回退到 ${XRAY_GO_SAFE_VER}"
fi

if [ -z "$XRAY_NEED" ] || version_gt "$XRAY_NEED" "$GO_TOOLCHAIN_MAX"; then
  if [ "$XRAY_CUR" = "$XRAY_GO_SAFE_VER" ]; then
    log "Xray-core 已是兼容版本 ${XRAY_GO_SAFE_VER}"
  else
    log "Xray-core ${XRAY_CUR} 需要 go ${XRAY_NEED:-未知} > ${GO_TOOLCHAIN_MAX}，回退到 ${XRAY_GO_SAFE_VER}"
    sed -i -e "s/^PKG_VERSION[[:space:]]*:=.*/PKG_VERSION:=${XRAY_GO_SAFE_VER}/" \
           -e "s/^PKG_HASH[[:space:]]*:=.*/PKG_HASH:=${XRAY_GO_SAFE_HASH}/" "$XRAY_MK"
    grep -qx "PKG_VERSION:=${XRAY_GO_SAFE_VER}" "$XRAY_MK" \
      || die "Xray-core 回退写入失败（Makefile: $XRAY_MK）"
    # 回退后复核，确保目标版本确实兼容（防止常量过期）
    after="$(go_mod_requirement "XTLS/Xray-core" "v${XRAY_GO_SAFE_VER}" || true)"
    if [ -n "$after" ] && version_gt "$after" "$GO_TOOLCHAIN_MAX"; then
      die "回退目标 ${XRAY_GO_SAFE_VER} 仍要求 go ${after}，常量已过期，请更新 XRAY_GO_SAFE_VER/HASH"
    fi
  fi
else
  log "Xray-core ${XRAY_CUR} 需要 go ${XRAY_NEED}，兼容（<= ${GO_TOOLCHAIN_MAX}）"
fi

# --- sing-box：无预设回退版本，超限则大声失败，绝不静默编出坏固件 ---
SB_MK="${PKG_CORE}/sing-box/Makefile"
SB_CUR="$(pkg_version "$SB_MK")"
[ -n "$SB_CUR" ] || die "未能读取 sing-box 版本"
SB_NEED="$(go_mod_requirement "SagerNet/sing-box" "v${SB_CUR}" || true)"
if [ -n "$SB_NEED" ] && version_gt "$SB_NEED" "$GO_TOOLCHAIN_MAX"; then
  die "sing-box ${SB_CUR} 要求 go ${SB_NEED} > ${GO_TOOLCHAIN_MAX}，且未预设兼容回退版本。"\
"请升级 feed 的 golang 或手动 pin sing-box 版本后再编译"
fi
[ -n "$SB_NEED" ] && log "sing-box ${SB_CUR} 需要 go ${SB_NEED}，兼容"

# ------------------------------------------------------------------------------
# 5. 版本一致性校验 + 输出（供 Release 说明使用，避免手写漂移）
# ------------------------------------------------------------------------------
XRAY_VER="$(pkg_version "${PKG_CORE}/xray-core/Makefile")"
SB_VER="$(pkg_version "${PKG_CORE}/sing-box/Makefile")"
PW_VER="$(pkg_version "$PKG_LUCI_MK")"

[ -n "$XRAY_VER" ] || die "未能读取 xray-core 版本"
[ -n "$SB_VER" ]   || die "未能读取 sing-box 版本"
[ -n "$PW_VER" ]   || die "未能读取 luci-app-passwall 版本（Makefile: $PKG_LUCI_MK）"

# 配置与脚本一致性校验：声明要用的必须真的启用
for p in luci-app-passwall; do
  config_enabled "$p" || die "配置未启用 ${p}，但本脚本假定其已启用。请检查 .config 或调整脚本"
done

emit_env "XRAY_VERSION"    "$XRAY_VER"
emit_env "SINGBOX_VERSION" "$SB_VER"
emit_env "PASSWALL_VERSION" "$PW_VER"

log "Passwall=${PW_VER}  Xray-core=${XRAY_VER}  Sing-box=${SB_VER}"
log "libwrt.sh 执行完成"
