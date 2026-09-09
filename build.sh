#!/bin/bash
# build.sh – 同时构建 release 与 debug
#
# 包信息（包名、版本、依赖、冲突等）由仓库根目录的 control.release /
# control.debug 两个文件描述；脚本将对应文件通过 Theos 的
# _THEOS_DEB_PACKAGE_CONTROL_PATH 传给构建系统

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"
CONTROL_VAR=_THEOS_DEB_PACKAGE_CONTROL_PATH

# 读取 Theos 写入 .theos/last_package 的产物路径，最可靠；
# 需在 make package 完成后调用。
last_package() {
    local package
    package=$(<"$PROJECT_DIR/.theos/last_package")
    case "$package" in
        /*) printf '%s\n' "$package" ;;
        *) printf '%s/%s\n' "$PROJECT_DIR" "$package" ;;
    esac
}

# 按包名、版本、架构模式在 packages/ 与根目录搜索 .deb，
find_deb() {
    local pkg="$1"
    local version="$2"
    local deb_file=""
    local candidate
    for candidate in \
        "$PROJECT_DIR/packages/${pkg}_${version}_iphoneos-arm64.deb" \
        "$PROJECT_DIR/packages/${pkg}_${version}_iphoneos-arm.deb" \
        "$PROJECT_DIR/packages/${pkg}_${version}*_iphoneos-arm64.deb" \
        "$PROJECT_DIR/packages/${pkg}_${version}*_iphoneos-arm.deb" \
        "$PROJECT_DIR/${pkg}_${version}_iphoneos-arm64.deb" \
        "$PROJECT_DIR/${pkg}_${version}_iphoneos-arm.deb" ; do
        if [ -f "$candidate" ]; then
            deb_file="$candidate"
            break
        fi
    done

    if [ -z "$deb_file" ]; then
        local glob_pattern="$PROJECT_DIR/packages/${pkg}_*.deb"
        shopt -s nullglob
        local matches=( $glob_pattern )
        shopt -u nullglob
        if [ ${#matches[@]} -gt 0 ]; then
            deb_file="${matches[0]}"
        fi
    fi
    printf '%s\n' "$deb_file"
}

# 构建函数：把给定的 control 文件经 _THEOS_DEB_PACKAGE_CONTROL_PATH 传给
# Theos。文件必须存在，缺失时直接报错，避免 Theos 回落到仓库默认 control。
build() {
    local control="$1"
    local is_release="${2:-false}"
    local package version deb_file

    [ -f "$control" ] || {
        echo "错误: 缺少 control 文件 $control" >&2
        exit 1
    }

    package=$(grep -i "^Package:" "$control" | cut -d' ' -f2-)
    version=$(grep -i "^Version:" "$control" | cut -d' ' -f2-)

    echo "▶ 构建 ${package} - 版本 ${version} ($(basename "$control"))"
    if [ "$is_release" = "true" ]; then
        echo "  模式: Release (FINALPACKAGE=1)"
        make clean >/dev/null 2>&1 || true
        make package FINALPACKAGE=1 "$CONTROL_VAR=$control"
    else
        echo "  模式: Debug"
        make clean >/dev/null 2>&1 || true
        make package "$CONTROL_VAR=$control"
    fi

    if [ -f "$PROJECT_DIR/.theos/last_package" ]; then
        deb_file="$(last_package)"
    else
        deb_file="$(find_deb "$package" "$version")"
    fi

    mkdir -p "$PROJECT_DIR/debs"
    if [ -n "$deb_file" ] && [ -f "$deb_file" ]; then
        mv "$deb_file" "$PROJECT_DIR/debs/"
        echo "  ✅ 已保存至 debs/$(basename "$deb_file")"
    else
        echo "  ⚠️ 未找到预期的 .deb 文件（已搜索 packages/ 与根目录）"
        exit 1
    fi
}

build_release() {
    build "$PROJECT_DIR/control.release" "true"
}

build_debug() {
    build "$PROJECT_DIR/control.debug" "false"
}

build_all() {
    build_release
    build_debug
    echo "全部构建完成，.deb 文件位于 debs/ 目录"
}

usage() {
    echo "Usage: $0 [build [release|debug]|build all]"
    echo "默认不传参数时执行双包构建。"
    echo "包信息由仓库根目录的 control.release 与 control.debug 两个文件描述。"
}

case "${1:-build}" in
    "build")
        case "${2:-all}" in
            "release")
                build_release
                ;;
            "debug")
                build_debug
                ;;
            "all"|"")
                build_all
                ;;
            *)
                usage
                exit 1
                ;;
        esac
        ;;
    "all"|"")
        build_all
        ;;
    *)
        usage
        exit 1
        ;;
 esac