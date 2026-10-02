#!/usr/bin/env zsh
#
# distribute_mac.sh — EhViewer-Nya macOS 自动构建 + 签名 + 公证 + DMG 打包
#
# 用法:
#   ./distribute_mac.sh           需要付费账号: Developer ID 签名 + 公证 + DMG
#   ./distribute_mac.sh --local   零账号: ad-hoc 签名 + DMG（自行放行后使用）
#
# 前置条件（仅分发模式需要）:
#   1. 已安装 Xcode 26+ 并登录 Apple Developer 账号
#   2. Keychain 中已导入 "Developer ID Application" 证书
#   3. 配置环境变量（直接 export 或写入 .env 文件）:
#        TEAM_ID            — 开发者团队 ID（必填）
#        公证凭据二选一:
#          NOTARY_PROFILE   — 钥匙串里的 notarytool profile
#                             (xcrun notarytool store-credentials <name> ...)
#        APPLE_ID           — Apple 开发者账号邮箱
#        APP_SPECIFIC_PASSWORD — App 专用密码
#        (设了 NOTARY_PROFILE 就不需要 APPLE_ID / APP_SPECIFIC_PASSWORD)
#
# 输出:
#   build/EhViewer-Nya-<version>.dmg
#     分发模式 — 已公证，双击即装，无 Gatekeeper 警告
#     本地模式 — ad-hoc 签名，本机可跑；传给别人对方需手动放行
#

set -euo pipefail

# ─────────────────────────── 颜色输出 ───────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { echo "${CYAN}[INFO]${NC} $*"; }
success() { echo "${GREEN}[✔]${NC} $*"; }
warn()    { echo "${YELLOW}[⚠]${NC} $*"; }
fail()    { echo "${RED}[✘]${NC} $*" >&2; exit 1; }

# ─────────────────────────── 项目常量 ───────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
PROJECT_FILE="$PROJECT_DIR/ehviewer nya.xcodeproj"
SCHEME="ehviewer nya"
APP_NAME="ehviewer nya"
BUNDLE_ID="io.github.ShiroiTree.Ehviewer-Nya"

BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/${APP_NAME}.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/${APP_NAME}.app"
DMG_DIR="$BUILD_DIR/dmg_staging"
SOURCE_ENTITLEMENTS="$PROJECT_DIR/ehviewer nya/ehviewer_nya.entitlements"
DIST_ENTITLEMENTS="$BUILD_DIR/entitlements-dist.plist"

# ─────────────────────────── 构建模式 ───────────────────────────
# dist  — Developer ID 签名 + 公证 + DMG，需要付费账号，产物可直接分发
# local — ad-hoc 签名 + DMG，零账号，产物仅供本机（或对方自行放行后）使用
MODE="dist"

usage() {
    echo "用法: ./distribute_mac.sh [--local]"
    echo ""
    echo "  (无参数)   Developer ID 签名 + 公证的 DMG，需要付费开发者账号"
    echo "  --local    ad-hoc 签名 + DMG，不需要任何账号与证书"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --local)   MODE="local" ;;
            -h|--help) usage; exit 0 ;;
            *)         usage >&2; fail "未知参数: $1" ;;
        esac
        shift
    done
}

# ─────────────────────────── 加载环境变量 ───────────────────────────
load_env() {
    # 按优先级: 当前目录 .env → 项目目录 .env
    local env_files=("$PWD/.env" "$PROJECT_DIR/.env" "$HOME/.ehviewer-nya.env")
    for f in "${env_files[@]}"; do
        if [[ -f "$f" ]]; then
            info "从 $f 加载环境变量"
            # 安全加载: 只读取 KEY=VALUE 行, 忽略注释和空行
            while IFS='=' read -r key value; do
                key=$(echo "$key" | xargs)               # trim
                [[ -z "$key" || "$key" == \#* ]] && continue
                value=$(echo "$value" | xargs | sed "s/^['\"]//;s/['\"]$//")  # trim + unquote
                export "$key=$value" 2>/dev/null || true
            done < "$f"
            break
        fi
    done
}

load_env

# ─────────────────────────── 验证环境 ───────────────────────────
check_prerequisites() {
    info "检查环境..."

    # Xcode
    command -v xcodebuild &>/dev/null || fail "未找到 xcodebuild，请安装 Xcode"
    local xcode_ver
    # 用 sed 取首行而非 head：head 读满即关管道，上游会吃到 SIGPIPE，
    # 在 set -o pipefail 下足以让整个脚本以 141 退出。sed 会读完整个流。
    xcode_ver=$(xcodebuild -version | sed -n '1p')
    info "  $xcode_ver"

    # codesign / hdiutil
    command -v codesign &>/dev/null || fail "未找到 codesign"
    command -v hdiutil  &>/dev/null || fail "未找到 hdiutil"

    # 本地模式到此为止：不需要账号、证书、描述文件。
    # 签名走 ad-hoc（"-"），DMG 不签也不公证——那两件事都建立在
    # Developer ID 证书之上，没有账号时做了 Gatekeeper 也不会认。
    if [[ "$MODE" == "local" ]]; then
        SIGNING_IDENTITY="-"
        info "  模式: 本地 (ad-hoc 签名，不公证，无需开发者账号)"
        success "环境检查通过"
        return
    fi

    # notarytool
    xcrun notarytool --version &>/dev/null || fail "未找到 notarytool (需要 Xcode 13+)"

    # 公证凭据: 优先用钥匙串 profile (xcrun notarytool store-credentials)，
    # 否则回退到 Apple ID + App 专用密码。
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        info "  公证凭据: keychain profile '$NOTARY_PROFILE'"
    else
        [[ -n "${APPLE_ID:-}" ]]              || fail "缺少 APPLE_ID 环境变量 (或设置 NOTARY_PROFILE 用钥匙串凭据)"
        [[ -n "${APP_SPECIFIC_PASSWORD:-}" ]] || fail "缺少 APP_SPECIFIC_PASSWORD 环境变量 (或设置 NOTARY_PROFILE)"
    fi
    [[ -n "${TEAM_ID:-}" ]] || fail "缺少 TEAM_ID 环境变量 (开发者团队 ID)"

    # Developer ID Application 证书
    local cert_name
    cert_name=$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" || true)
    if [[ -z "$cert_name" ]]; then
        fail "Keychain 中未找到 \"Developer ID Application\" 证书。\n请在 Xcode → Settings → Accounts → 管理证书 中创建，或从 developer.apple.com 下载安装。"
    fi
    SIGNING_IDENTITY=$(echo "$cert_name" | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+[A-F0-9]+[[:space:]]+"(.+)"/\1/')
    info "  签名身份: $SIGNING_IDENTITY"

    success "环境检查通过"
}

# keychain-access-groups 是受限 entitlement，值里的 $(AppIdentifierPrefix) 只能由
# 描述文件展开。仓库不带 Developer ID 描述文件，带它归档会直接报
# "requires a provisioning profile"。本 App 非沙盒、也不跨 App 共享钥匙串，
# 用默认访问组即可（EhCredentialStore 不指定 access group），所以分发构建去掉它。
prepare_entitlements() {
    cp "$SOURCE_ENTITLEMENTS" "$DIST_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$DIST_ENTITLEMENTS" 2>/dev/null || true
    info "分发用 entitlements: 已去掉 keychain-access-groups"
}

# ─────────────────────────── 1. 构建 Archive ───────────────────────────
# xcodebuild 的失败原因通常埋在几千行日志中间，而结尾只留一句
# "The following build commands failed"。所以整体落盘，失败时把
# error: / 签名相关的行挑出来。
# 另外不能直接管道给 tail：set -e + pipefail 会让脚本在管道失败那一刻就
# 退出，后面那句兜底报错永远轮不到执行。
run_archive() {
    local log="$BUILD_DIR/archive.log"
    if xcodebuild archive "$@" > "$log" 2>&1; then
        tail -3 "$log" | sed 's/^/  /'
    else
        echo "" >&2
        grep -nE "error:|error :|The following build commands failed|requires a development team|requires a provisioning profile|No signing certificate|invalid entitlement|CodeSign|does not contain" "$log" \
            | tail -30 | sed 's/^/  /' >&2 || true
        fail "Archive 构建失败。完整日志: $log"
    fi
}

build_archive() {
    info "清理旧产物..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    if [[ "$MODE" == "local" ]]; then
        # 归档阶段完全不签名，理由不是「省事」，而是没得选：
        # 工程 entitlements 里的 keychain-access-groups 是受限 entitlement，
        # 值里的 $(AppIdentifierPrefix) 只有描述文件能提供，而描述文件又要有
        # 团队身份。于是手动签名会直接报 "requires a provisioning profile"。
        # 关掉签名反而绕过整套签名/描述文件协商——build.yml 的 macOS 那步
        # 就是这么做的。ad-hoc 签名改在 deep_codesign() 里补。
        info "构建 Release Archive (暂不签名)..."
        run_archive \
            -project "$PROJECT_FILE" \
            -scheme "$SCHEME" \
            -destination "platform=macOS" \
            -configuration Release \
            -archivePath "$ARCHIVE_PATH" \
            CODE_SIGN_IDENTITY="" \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGNING_ALLOWED=NO
    else
        prepare_entitlements
        info "构建 Release Archive..."
        run_archive \
            -project "$PROJECT_FILE" \
            -scheme "$SCHEME" \
            -destination "platform=macOS" \
            -configuration Release \
            -archivePath "$ARCHIVE_PATH" \
            CODE_SIGN_STYLE=Manual \
            CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
            CODE_SIGN_ENTITLEMENTS="$DIST_ENTITLEMENTS" \
            DEVELOPMENT_TEAM="$TEAM_ID" \
            OTHER_CODE_SIGN_FLAGS="--options runtime --timestamp"
    fi

    [[ -d "$ARCHIVE_PATH" ]] || fail "Archive 构建失败，请检查完整日志"
    success "Archive 构建完成: $ARCHIVE_PATH"
}

# ─────────────────────────── 2. 导出 .app ───────────────────────────
export_app() {
    # 本地模式没有可用的导出方式：-exportArchive 的每个 method
    # （developer-id / app-store / ad-hoc）都要求真实签名身份或描述文件。
    # 而归档里的 .app 在 archive 阶段就已经 ad-hoc 签好了，取出来即可。
    if [[ "$MODE" == "local" ]]; then
        info "从归档取出 .app..."
        local archived_app="$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app"
        [[ -d "$archived_app" ]] || fail "归档里找不到 .app: $archived_app"
        rm -rf "$EXPORT_DIR"
        mkdir -p "$EXPORT_DIR"
        cp -R "$archived_app" "$APP_PATH"
        success ".app 就绪: $APP_PATH"
        return
    fi

    info "导出 .app..."
    mkdir -p "$EXPORT_DIR"

    # 生成 ExportOptions.plist
    local export_plist="$BUILD_DIR/ExportOptions.plist"
    cat > "$export_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>provisioningProfiles</key>
    <dict/>
</dict>
</plist>
EOF

    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist "$export_plist" \
        2>&1 | tail -5

    [[ -d "$APP_PATH" ]] || fail ".app 导出失败"
    success ".app 导出完成: $APP_PATH"
}

# ─────────────────────────── 3. 深度重签名 ───────────────────────────
deep_codesign() {
    if [[ "$MODE" == "local" ]]; then
        # 归档时跳过了签名，这里补上 ad-hoc。这一步不能省：
        # Apple Silicon 的内核要求所有 arm64 可执行文件至少有 ad-hoc 签名，
        # 完全未签名的二进制一启动就被杀，"归档成功" 不等于 "能运行"。
        #
        # 不带 --entitlements。工程那份里唯一起作用的是 keychain-access-groups，
        # 而它依赖描述文件提供 $(AppIdentifierPrefix)，ad-hoc 无从展开；其余几条
        # （关沙盒 / 网络 / 用户选择文件）只对沙盒 App 有意义，本地这份本来就不
        # 沙盒，给不给都一样。代价是钥匙串用不了——App 会自己退回持久 Cookie。
        # 也不带 --options runtime：Hardened Runtime 是公证的前置条件，
        # 本地既没有公证也不打算有。
        info "ad-hoc 签名 .app..."
        codesign --force --deep --sign - "$APP_PATH" 2>&1 | sed 's/^/  /'
        codesign --verify "$APP_PATH" >/dev/null 2>&1 \
            && success "ad-hoc 签名完成并验证通过" \
            || warn "签名校验未通过，本机启动可能被内核拒绝"
        return
    fi

    info "深度签名 .app (Hardened Runtime)..."

    # 对所有嵌入的框架/dylib 逐一签名 (由内向外)
    find "$APP_PATH/Contents/Frameworks" -type f \( -name "*.dylib" -o -name "*.framework" \) -print0 2>/dev/null | while IFS= read -r -d '' fw; do
        codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$fw" 2>/dev/null || true
    done

    # 对 .app 整体深度签名
    codesign --force --deep --options runtime --timestamp \
        --entitlements "$DIST_ENTITLEMENTS" \
        --sign "$SIGNING_IDENTITY" \
        "$APP_PATH"

    # 验证签名
    codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 || fail "签名验证失败"
    success "签名完成并验证通过"
}

# ─────────────────────────── 4. 打包 DMG ───────────────────────────
create_dmg() {
    info "创建 DMG 安装包..."

    # 从 Info.plist 读取版本号
    local version
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "1.0.0")

    local dmg_name="EhViewer-Nya-${version}.dmg"
    local dmg_path="$BUILD_DIR/$dmg_name"
    local dmg_temp="$BUILD_DIR/${dmg_name%.dmg}-temp.dmg"

    rm -rf "$DMG_DIR"
    mkdir -p "$DMG_DIR"

    # 复制 .app 到临时目录
    cp -R "$APP_PATH" "$DMG_DIR/"

    # 创建 Applications 快捷方式
    ln -s /Applications "$DMG_DIR/Applications"

    # 创建临时可写 DMG
    local vol_name="EhViewer Nya"
    hdiutil create -ov -srcfolder "$DMG_DIR" -volname "$vol_name" \
        -fs HFS+ -fsargs "-c c=64,a=16,e=16" \
        -format UDRW "$dmg_temp" 2>/dev/null

    # 挂载并美化
    local device
    device=$(hdiutil attach -readwrite -noverify "$dmg_temp" | grep "Apple_HFS" | awk '{print $1}')

    # AppleScript 设置窗口外观
    osascript <<APPLESCRIPT
    tell application "Finder"
        tell disk "$vol_name"
            open
            set the bounds of container window to {400, 100, 920, 440}
            set current view of container window to icon view
            set arrangement of icon view options of container window to not arranged
            set icon size of icon view options of container window to 80
            set background color of icon view options of container window to {65535, 65535, 65535}
            set position of item "${APP_NAME}.app" of container window to {130, 170}
            set position of item "Applications" of container window to {390, 170}
            close
        end tell
    end tell
APPLESCRIPT

    sync
    hdiutil detach "$device" 2>/dev/null || true

    # 压缩为只读 DMG
    hdiutil convert "$dmg_temp" -format UDZO -imagekey zlib-level=9 -o "$dmg_path"
    rm -f "$dmg_temp"
    rm -rf "$DMG_DIR"

    # 给 DMG 本身签名。此前只签了 .app，外层映像没有签名，
    # Gatekeeper 以 --type open 评估时会以 "no usable signature" 拒绝。
    # 必须在公证之前完成——公证的对象就是最终分发的这个文件。
    #
    # 本地模式跳过：这层签名是给公证用的，没有 Developer ID 时
    # Gatekeeper 照样不认，只是白做一遍。
    if [[ "$MODE" == "local" ]]; then
        info "跳过 DMG 签名 (ad-hoc 模式下无意义)"
    else
        info "为 DMG 签名..."
        codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$dmg_path"
    fi

    DMG_PATH="$dmg_path"
    if [[ "$MODE" == "local" ]]; then
        success "DMG 已创建: $DMG_PATH"
    else
        success "DMG 已创建并签名: $DMG_PATH"
    fi
}

# ─────────────────────────── 5. 公证 DMG ───────────────────────────
notarize_dmg() {
    info "提交 DMG 到 Apple 公证服务 (这可能需要几分钟)..."

    local log_file="$BUILD_DIR/notarization.log"

    local creds
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        creds=(--keychain-profile "$NOTARY_PROFILE")
    else
        creds=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_SPECIFIC_PASSWORD")
    fi

    xcrun notarytool submit "$DMG_PATH" "${creds[@]}" \
        --wait \
        --timeout 30m \
        2>&1 | tee "$log_file"

    # 检查公证结果
    if grep -q "status: Accepted" "$log_file"; then
        success "公证通过！"
    else
        warn "公证可能失败，正在获取详细日志..."

        # 提取 submission ID 并查询日志
        local sub_id
        sub_id=$(grep -oE "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" "$log_file" | sed -n '1p' || true)
        if [[ -n "$sub_id" ]]; then
            info "Submission ID: $sub_id"
            xcrun notarytool log "$sub_id" "${creds[@]}" \
                "$BUILD_DIR/notarization-detail.json" 2>/dev/null || true

            if [[ -f "$BUILD_DIR/notarization-detail.json" ]]; then
                echo ""
                warn "公证详细日志:"
                cat "$BUILD_DIR/notarization-detail.json"
                echo ""
            fi
        fi

        fail "公证未通过，请检查上方日志。常见原因:\n  - Hardened Runtime 未启用\n  - 使用了被禁止的 API / 私有框架\n  - 签名不包含 timestamp"
    fi
}

# ─────────────────────────── 6. 植入公证票据 ───────────────────────────
staple_dmg() {
    info "植入公证票据 (Staple)..."
    xcrun stapler staple "$DMG_PATH" || fail "Staple 失败"

    # 验证
    xcrun stapler validate "$DMG_PATH" || fail "Staple 验证失败"
    success "票据植入完成"
}

# ─────────────────────────── 7. 最终验证 ───────────────────────────
final_verify() {
    info "最终验证..."

    # Gatekeeper 评估。DMG 是磁盘映像，必须用 --type open；
    # 默认的 execute 类型对映像永远得到 "no usable signature"。
    local assess
    assess=$(spctl --assess --type open --context context:primary-signature -vv "$DMG_PATH" 2>&1 || true)
    echo "$assess" | sed 's/^/  /'
    if ! echo "$assess" | grep -q "accepted"; then
        fail "Gatekeeper 拒绝了这个 DMG，不要分发。\n$assess"
    fi

    # 票据必须能离线校验，否则用户断网时仍会被拦
    xcrun stapler validate "$DMG_PATH" >/dev/null 2>&1 \
        || fail "公证票据未正确植入 DMG"

    local size
    size=$(du -sh "$DMG_PATH" | awk '{print $1}')
    local version
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "1.0.0")

    echo ""
    echo "${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo "${GREEN}${BOLD}  ✅ 构建完成！${NC}"
    echo "${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  应用名称:   EhViewer-Nya"
    echo "  版本号:     ${version}"
    echo "  Bundle ID:  ${BUNDLE_ID}"
    echo "  文件大小:   ${size}"
    echo ""
    echo "  ${BOLD}输出文件:${NC}"
    echo "  ${CYAN}${DMG_PATH}${NC}"
    echo ""
    echo "  签名状态:   ✅ Developer ID (有效期约1年)"
    echo "  公证状态:   ✅ Apple Notarized"
    echo "  票据植入:   ✅ Stapled"
    echo ""
    echo "  可直接分发给用户，双击 DMG → 拖入 Applications → 运行"
    echo "  无 Gatekeeper 警告，无需右键打开"
    echo "${BOLD}═══════════════════════════════════════════════════════════${NC}"
}

# ──────────────────── 7L. 最终验证（本地模式）────────────────────
# spctl 在这里必然给出 rejected——没有 Developer ID 就换不来 accepted，
# 那不是失败，是这种构建方式的性质。所以不查 Gatekeeper，只查
# 「DMG 挂得上、里面的 app 是有效签名」，再把放行方式讲明白。
final_verify_local() {
    info "验证 DMG 可挂载..."

    local attach_out mount_point
    # 末尾的 || true 是为了让挂载失败也走下面那条自己的报错，
    # 否则 set -e 会直接带着 hdiutil 的原始输出退出。
    attach_out=$(hdiutil attach -nobrowse -readonly "$DMG_PATH" || true)
    # 卷名带空格，不能用 awk 取列；这里从行首贪婪匹配到 /Volumes/ 起点。
    mount_point=$(echo "$attach_out" | sed -n 's|.*\(/Volumes/.*\)|\1|p' | sed -n '1p')

    if [[ -z "$mount_point" || ! -d "$mount_point" ]]; then
        fail "DMG 挂载失败: $DMG_PATH"
    fi
    ls -1 "$mount_point" | sed 's/^/  /'
    hdiutil detach "$mount_point" >/dev/null 2>&1 || true
    success "DMG 可正常挂载"

    # .app 必须带有效签名。Apple Silicon 上完全未签名的 arm64 二进制会被
    # 内核直接杀掉，所以「DMG 能打开」不等于「app 能运行」，要单独验。
    if codesign --verify "$APP_PATH" >/dev/null 2>&1; then
        success ".app 签名有效 (ad-hoc)"
    else
        warn ".app 未通过签名校验，本机启动可能被内核拒绝"
    fi

    local size version
    size=$(du -sh "$DMG_PATH" | awk '{print $1}')
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "0.1.0")

    echo ""
    echo "${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo "${GREEN}${BOLD}  ✅ 本地构建完成！${NC}"
    echo "${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  应用名称:   EhViewer-Nya"
    echo "  版本号:     ${version}"
    echo "  Bundle ID:  ${BUNDLE_ID}"
    echo "  文件大小:   ${size}"
    echo ""
    echo "  ${BOLD}输出文件:${NC}"
    echo "  ${CYAN}${DMG_PATH}${NC}"
    echo ""
    echo "  签名状态:   ${YELLOW}⚠️  ad-hoc（仅本机可信）${NC}"
    echo "  公证状态:   ${YELLOW}❌ 未公证（没有付费开发者账号）${NC}"
    echo ""
    echo "  ${BOLD}本机安装:${NC} 双击 DMG → 拖入 Applications → 打开"
    echo "  ${BOLD}首次被拦:${NC} 右键 → 打开 在 macOS 15+ 已不再提供绕过入口，"
    echo "             改到 系统设置 → 隐私与安全性 → 仍要打开"
    echo "             或执行: xattr -dr com.apple.quarantine \"/Applications/${APP_NAME}.app\""
    echo ""
    echo "  ${BOLD}传给别人:${NC} 对方必定会遇到 Gatekeeper 拦截，需按上面同一步自行放行"
    echo ""
    echo "  ${YELLOW}注意${NC} ad-hoc 签名不带 application-identifier，钥匙串可能写入失败"
    echo "       （errSecMissingEntitlement / -34018）——App 会退回持久 Cookie，"
    echo "       表现为登录态更容易掉。要避免就换带团队身份的签名。"
    echo ""
    echo "${BOLD}═══════════════════════════════════════════════════════════${NC}"
}

# ─────────────────────────── 主流程 ───────────────────────────
main() {
    parse_args "$@"

    echo ""
    if [[ "$MODE" == "local" ]]; then
        echo "${BOLD}🍎 EhViewer-Nya macOS 本地构建 (ad-hoc)${NC}"
    else
        echo "${BOLD}🍎 EhViewer-Nya macOS 分发构建${NC}"
    fi
    echo "${BOLD}════════════════════════════════${NC}"
    echo ""

    check_prerequisites
    echo ""
    build_archive
    echo ""
    export_app
    echo ""
    deep_codesign
    echo ""
    create_dmg
    echo ""

    if [[ "$MODE" == "local" ]]; then
        final_verify_local
    else
        notarize_dmg
        echo ""
        staple_dmg
        echo ""
        final_verify
    fi
}

main "$@"
