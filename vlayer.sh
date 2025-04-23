#!/bin/bash

# VLayer 一键安装与测试脚本 v17（修改为单用户支持）
# 特性：
# - 支持单个 API Token 和 Private Key，生成 JSON 格式
# - 每个项目只为一个账户执行 Testnet，失败不会中断
# - 自动无限循环测试，每 10 分钟重复
# - 批量 ETH 转账：固定金额，逐行输入地址，失败重试 2 次，显示最终失败地址

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo_info() {
    echo -e "${GREEN}[信息] $1${NC}"
}

echo_error() {
    echo -e "${RED}[错误] $1${NC}"
}

check_and_install() {
    if ! command -v $1 &> /dev/null; then
        echo_info "正在安装 $1..."
        eval "$2"
    else
        echo_info "$1 已安装，跳过"
    fi
}

install_dependencies() {
    echo_info "🔄 更新系统中..."
    apt update  # 只运行一次更新

    echo_info "📦 安装基础依赖..."
    check_and_install curl "apt install -y curl"
    check_and_install unzip "apt install -y unzip"
    check_and_install git "apt install -y git"
    check_and_install jq "apt install -y jq"
    check_and_install screen "apt install -y screen"
    check_and_install node "curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt install -y nodejs"

    # Docker
    if ! command -v docker &> /dev/null; then
        echo_info "📦 安装 Docker..."
        apt install -y ca-certificates gnupg lsb-release
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
            $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt update
        apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    else
        echo_info "✅ Docker 已安装，跳过"
    fi

    # Rust
    if ! command -v rustup &> /dev/null; then
        echo_info "🦀 安装 Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    fi
    source $HOME/.cargo/env
    rustup update

    # Foundry
    if ! command -v foundryup &> /dev/null; then
        echo_info "🔨 安装 Foundry..."
        curl -L https://foundry.paradigm.xyz | bash
    fi
    export PATH="$HOME/.foundry/bin:$PATH"
    echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> ~/.bashrc
    foundryup

    # Bun
    if ! command -v bun &> /dev/null; then
        echo_info "⚡ 安装 Bun..."
        curl -fsSL https://bun.sh/install | bash
    fi
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"
    echo 'export BUN_INSTALL="$HOME/.bun"' >> ~/.bashrc
    echo 'export PATH="$BUN_INSTALL/bin:$PATH"' >> ~/.bashrc

    # VLayer CLI
    if ! command -v vlayerup &> /dev/null; then
        echo_info "🌐 安装 VLayer CLI..."
        curl -SL https://install.vlayer.xyz | bash
    fi
    export PATH="$HOME/.vlayer/bin:$PATH"
    echo 'export PATH="$HOME/.vlayer/bin:$PATH"' >> ~/.bashrc
    vlayerup

    echo_info "所有依赖安装完成 ✅"
}

init_project_only() {
    name=$1
    template=$2
    mkdir -p vlayer
    cd vlayer
    if [ -d "$name" ]; then
        echo_info "⚠️ 项目 $name 已存在。请选择："
        echo -e "${YELLOW}1. 跳过（保留原项目）"
        echo -e "2. 删除并重新安装${NC}"
        read -rp "请输入选项编号（默认跳过）：" action_choice
        case "$action_choice" in
            2)
                echo_info "正在删除旧项目目录 $name..."
                rm -rf "$name"
                ;;

            *)
                echo_info "已选择跳过安装 $name"
                cd .. 
                return
                ;;
        esac
    fi

    echo_info "初始化项目：$name（模板：$template）"
    vlayer init "$name" --template "$template"
    cd "$name"
    forge build
    cd vlayer
    bun install
    cd ../../../
    echo_info "✅ $name 安装完成"
}

generate_key_files() {
    mkdir -p vlayer
    echo_info "请输入 VLayer API Token 和 Private Key"
    read -rp "API Token: " token
    if [ -z "$token" ]; then
        echo_error "API Token 不能为空"
        return
    fi
    read -rp "Private Key: " private_key
    if [ -z "$private_key" ]; then
        echo_error "Private Key 不能为空"
        return
    fi

    # 生成 JSON 格式的 api.json 和 key.json
    api_json="[\"$token\"]"
    key_json="[\"$private_key\"]"

    echo "$api_json" > vlayer/api.json
    echo "$key_json" > vlayer/key.json
    echo_info "已生成 vlayer/api.json 和 vlayer/key.json（单账户 JSON 格式）"
}

test_with_testnet() {
    project_dir=$1
    if [ ! -d "vlayer/$project_dir/vlayer" ]; then
        echo_error "❌ 项目目录 vlayer/$project_dir/vlayer 不存在，请先安装"
        return 1
    fi
    echo_info "准备 Testnet 测试：$project_dir"
    cd "vlayer/$project_dir/vlayer"

    if [[ -f ../../api.json && -f ../../key.json ]]; then
        # 读取单一 API Token 和 Private Key
        api_token=$(cat ../../api.json | jq -r '.[0]')
        private_key=$(cat ../../key.json | jq -r '.[0]')

        echo_info "正在为账户进行测试：$api_token"
        echo_info "生成 .env.testnet.local 文件"
        cat <<EOF > .env.testnet.local
VLAYER_API_TOKEN=$api_token
EXAMPLES_TEST_PRIVATE_KEY=$private_key
CHAIN_NAME=optimismSepolia
JSON_RPC_URL=https://sepolia.optimism.io
EOF

        echo_info "开始运行 Testnet 证明..."
        if ! bun run prove:testnet; then
            echo_error "❌ 测试失败"
        else
            echo_info "✅ 测试成功"
        fi
    else
        echo_error "❌ 缺少 api.json 或 key.json 文件"
        cd ../../../
        return 1
    fi
    cd ../../../
    return 0
}

# ... (其余代码保持不变)

show_menu() {
    echo -e "${YELLOW}
========= VLayer 示例工具菜单 =========
1. 环境安装
2. 安装测试项目
3. 对项目进行Testnet 测试（单项测试）
4. 生成 api.json 和 key.json（单账户）
5. 启动自动测试循环（每 10 分钟）
6. 批量 ETH 转账（使用 key.json 第一个私钥）
0. 退出脚本
=======================================
${NC}"
    read -rp "请输入选项编号：" choice
    case $choice in
        1) install_dependencies ;;
        2) show_project_menu ;;
        3) testnet_menu ;;
        4) generate_key_files ;;
        5) auto_test_loop ;;
        6) batch_transfer_eth ;;
        0) echo_info "退出脚本"; exit 0 ;;
        *) echo_error "无效选项，请重新运行脚本";;
    esac
}

echo_info "加载 bash 环境..."
source ~/.bashrc || source /root/.bashrc
export PATH="$HOME/.bun/bin:$HOME/.vlayer/bin:$HOME/.foundry/bin:$PATH"

while true; do
    show_menu
done
