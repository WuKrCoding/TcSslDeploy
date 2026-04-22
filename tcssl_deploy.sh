#!/bin/bash
# TcSslDeploy - 腾讯云SSL证书同步脚本
# 功能：对比并同步本地证书与腾讯云SSL证书

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 日志函数（全部输出到 stderr，避免污染命令替换的 stdout 返回值）
log_info() {
    [[ -n "$QUIET" ]] && return
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    [[ -n "$QUIET" ]] && return
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    [[ -z "$VERBOSE" ]] && return
    echo -e "${GREEN}[DEBUG]${NC} $1" >&2
}

# 帮助信息
show_help() {
    cat << EOF
用法: $(basename "$0") [选项]

模式一：手动管理单个证书
  $(basename "$0") -c <证书文件> -k <私钥文件> [-d <域名>] [选项]

模式二：计划任务批量检查（读取配置文件）
  $(basename "$0") --cron [-q] [-v]

必填参数:
  -c, --cert-file     证书文件路径 (full chain格式)
  -k, --key-file      私钥文件路径

选填参数:
  -d, --domain        域名 (不提供则从证书中提取；证书不存在时必须指定)
  -r, --restart       重启命令 (如: systemctl restart nginx)
  -f, --force         强制更新：跳过过期时间对比，直接部署最新可用证书
  -n, --no-backup     不备份：直接覆盖现有证书文件（默认会备份原文件）
      --cron          计划任务模式：读取配置文件批量检查并更新所有证书
  -q, --quiet         静默模式：只输出错误信息
  -v, --verbose       详细模式：输出 API 原始响应等调试信息
  -t, --test          测试腾讯云API密钥是否可用
  -h, --help          显示帮助信息

环境变量:
  TENCENTCLOUD_SECRET_ID    腾讯云 SecretId
  TENCENTCLOUD_SECRET_KEY   腾讯云 SecretKey
  TENCENTCLOUD_REGION       区域 (默认: ap-guangzhou)

配置文件:
  config.json   脚本同目录下的配置文件，自动存储所有证书配置及 API 密钥

示例:
  # 手动添加/更新一个证书（成功后会自动写入配置文件）
  $(basename "$0") -c /etc/nginx/ssl/server.crt -k /etc/nginx/ssl/server.key -d example.com -r "systemctl restart nginx"

  # 计划任务模式（由 crontab 调用）
  $(basename "$0") --cron -q
EOF
}

# 全局变量
CERT_FILE=""
KEY_FILE=""
DOMAIN=""
RESTART_CMD=""
TEST_MODE=""
FORCE_UPDATE=""
NO_BACKUP=""
QUIET=""
VERBOSE=""
CRON_MODE=""
CONFIG_FILE="${HOME}/.tcssl_deploy/config.json"

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--cert-file)
                CERT_FILE="$2"
                shift 2
                ;;
            -k|--key-file)
                KEY_FILE="$2"
                shift 2
                ;;
            -d|--domain)
                DOMAIN="$2"
                shift 2
                ;;
            -r|--restart)
                RESTART_CMD="$2"
                shift 2
                ;;
            -f|--force)
                FORCE_UPDATE="1"
                shift
                ;;
            -n|--no-backup)
                NO_BACKUP="1"
                shift
                ;;
            -q|--quiet)
                QUIET="1"
                shift
                ;;
            -v|--verbose)
                VERBOSE="1"
                shift
                ;;
            --cron)
                CRON_MODE="1"
                shift
                ;;
            -t|--test)
                TEST_MODE="1"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# 测试腾讯云API密钥
test_api_key() {
    log_info "========== 测试腾讯云API密钥 =========="

    if [[ "$(id -u)" -ne 0 ]]; then
        log_warn "当前非 root 用户运行，部分操作（如重启服务、修改系统证书目录）可能需要 root 权限"
    fi

    if [[ -z "$TENCENTCLOUD_SECRET_ID" ]]; then
        log_error "环境变量 TENCENTCLOUD_SECRET_ID 未设置"
        return 1
    fi

    if [[ -z "$TENCENTCLOUD_SECRET_KEY" ]]; then
        log_error "环境变量 TENCENTCLOUD_SECRET_KEY 未设置"
        return 1
    fi

    log_info "SecretId: ${TENCENTCLOUD_SECRET_ID:0:8}..."
    log_info "Region: ${TENCENTCLOUD_REGION:-ap-guangzhou}"

    # 调用证书列表接口测试
    local payload="{\"Limit\":1,\"Offset\":0}"
    local response=$(tccloud_api "DescribeCertificates" "$payload")

    log_debug "API响应: ${response:0:300}..."

    # 检查是否有错误
    if echo "$response" | grep -q '"Error"'; then
        local err_code=$(echo "$response" | sed -n 's/.*"Code"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        local err_msg=$(echo "$response" | sed -n 's/.*"Message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        log_error "密钥测试失败: ${err_code}"
        log_error "错误信息: ${err_msg}"
        return 1
    fi

    # 检查是否返回有效响应
    if echo "$response" | grep -q '"Response"'; then
        log_info "========== API密钥测试通过 =========="
        log_info "密钥状态: 有效"
        return 0
    else
        log_error "API响应格式异常"
        return 1
    fi
}

# 验证必需参数
validate_args() {
    if [[ -z "$CERT_FILE" ]]; then
        log_error "证书文件路径不能为空 (使用 -c 或 --cert-file 指定)"
        exit 1
    fi

    if [[ -z "$KEY_FILE" ]]; then
        log_error "私钥文件路径不能为空 (使用 -k 或 --key-file 指定)"
        exit 1
    fi

    # 检查腾讯云密钥
    if [[ -z "$TENCENTCLOUD_SECRET_ID" ]] || [[ -z "$TENCENTCLOUD_SECRET_KEY" ]]; then
        log_error "缺少腾讯云认证密钥，请设置环境变量 TENCENTCLOUD_SECRET_ID 和 TENCENTCLOUD_SECRET_KEY"
        exit 1
    fi
}

# 从证书文件提取域名
extract_domain_from_cert() {
    local cert_file="$1"
    # 从证书的Subject中提取CN作为域名
    local cn=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed -n 's/.*CN\s*=\s*\([^/,]*\).*/\1/p')
    echo "${cn// /}"
}

# 从证书文件提取过期时间
extract_expiry_from_cert() {
    local cert_file="$1"
    openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2
}

# 解析日期为时间戳
date_to_timestamp() {
    local date_str="$1"
    date -d "$date_str" +%s 2>/dev/null
}

# 腾讯云TC3-HMAC-SHA256签名
# 参考: https://cloud.tencent.com/document/product/213/30654
tc3_sign() {
    local secret_key="$1"
    local date="$2"
    local service="$3"
    local timestamp="$4"
    local action="$5"
    local payload_hash="$6"

    local algorithm="TC3-HMAC-SHA256"
    local action_lower=$(echo "$action" | tr '[:upper:]' '[:lower:]')

    # 步骤1: 拼接规范请求串（使用 printf 生成真正的换行符）
    # 注意: Bash $(...) 会删除末尾换行符，因此末尾加占位符 '.' 再截掉
    local canonical_headers
    canonical_headers=$(printf 'content-type:application/json; charset=utf-8\nhost:ssl.tencentcloudapi.com\nx-tc-action:%s\n.' "$action_lower")
    canonical_headers="${canonical_headers%.}"
    local signed_headers="content-type;host;x-tc-action"

    local canonical_request
    canonical_request=$(printf 'POST\n/\n\n%s\n%s\n%s' "$canonical_headers" "$signed_headers" "$payload_hash")

    # 步骤2: 拼接待签名字符串
    local credential_scope="${date}/${service}/tc3_request"
    local hashed_canonical_request
    hashed_canonical_request=$(printf '%s' "$canonical_request" | openssl dgst -sha256 | awk '{print $2}')
    local string_to_sign
    string_to_sign=$(printf '%s\n%s\n%s\n%s' "$algorithm" "$timestamp" "$credential_scope" "$hashed_canonical_request")

    # 步骤3: 计算签名
    # SecretDate = HMAC_SHA256("TC3" + SecretKey, Date)
    local secret_date
    secret_date=$(printf '%s' "$date" | openssl dgst -sha256 -hmac "TC3${secret_key}" 2>/dev/null | awk '{print $2}')
    # SecretService = HMAC_SHA256(SecretDate, Service)
    local secret_service
    secret_service=$(printf '%s' "$service" | openssl dgst -sha256 -mac hmac -macopt hexkey:"$secret_date" 2>/dev/null | awk '{print $2}')
    # SecretSigning = HMAC_SHA256(SecretService, "tc3_request")
    local secret_signing
    secret_signing=$(printf '%s' "tc3_request" | openssl dgst -sha256 -mac hmac -macopt hexkey:"$secret_service" 2>/dev/null | awk '{print $2}')
    # Signature = HMAC_SHA256(SecretSigning, StringToSign)
    local signature
    signature=$(printf '%s' "$string_to_sign" | openssl dgst -sha256 -mac hmac -macopt hexkey:"$secret_signing" 2>/dev/null | awk '{print $2}')

    echo "$signature"
}

# 腾讯云API调用
tccloud_api() {
    local action="$1"
    local payload="$2"

    local secret_id="$TENCENTCLOUD_SECRET_ID"
    local secret_key="$TENCENTCLOUD_SECRET_KEY"
    local region="${TENCENTCLOUD_REGION:-ap-guangzhou}"
    local service="ssl"
    local version="2019-12-05"

    local timestamp=$(date +%s)
    local date=$(date -u +%Y-%m-%d)
    local action_lower=$(echo "$action" | tr '[:upper:]' '[:lower:]')

    # 计算payload哈希
    local payload_hash
    payload_hash=$(printf '%s' "$payload" | openssl dgst -sha256 | awk '{print $2}')

    # 生成签名
    local signature=$(tc3_sign "$secret_key" "$date" "$service" "$timestamp" "$action" "$payload_hash")

    # 拼接Authorization
    local authorization="TC3-HMAC-SHA256 Credential=${secret_id}/${date}/${service}/tc3_request, SignedHeaders=content-type;host;x-tc-action, Signature=${signature}"

    # 发起请求（增加超时防止无限挂起）
    curl -s -X POST "https://ssl.tencentcloudapi.com/" \
        --connect-timeout 10 --max-time 30 \
        -H "Authorization: ${authorization}" \
        -H "Content-Type: application/json; charset=utf-8" \
        -H "Host: ssl.tencentcloudapi.com" \
        -H "X-TC-Action: ${action}" \
        -H "X-TC-Timestamp: ${timestamp}" \
        -H "X-TC-Version: ${version}" \
        -H "X-TC-Region: ${region}" \
        -d "$payload"
}

# 简单的JSON解析函数
json_get_string() {
    local json="$1"
    local key="$2"
    echo "$json" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

json_get_array_element() {
    local json="$1"
    local key="$2"
    local index="$3"
    echo "$json" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p" | tr ',' '\n' | sed -n "${index}p" | tr -d '"' | tr -d ' '
}

json_has_key() {
    local json="$1"
    local key="$2"
    echo "$json" | grep -q "\"${key}\"" && return 0 || return 1
}

# 增强的JSON解析函数 - 处理复杂嵌套JSON
json_extract() {
    local json="$1"
    local path="$2"

    # 支持简单的路径如 "Response.Certificates.0.CertEndTime"
    local current="$json"
    local IFS='.'

    for key in $path; do
        # 处理数组索引 [0]
        if [[ "$key" =~ \[([0-9]+)\] ]]; then
            local array_key="${key%%\[*}"
            local array_index="${BASH_REMATCH[1]}"

            if [[ -n "$array_key" ]]; then
                current=$(echo "$current" | sed -n "s/.*\"${array_key}\"[[:space:]]*:[[:space:]]*\[\(.*\)\]/\1/p")
            fi
            current=$(echo "$current" | tr '{' '\n' | sed -n "$((array_index + 1))p")
        else
            current=$(echo "$current" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\?\([^\",}]*\)\"\?.*/\1/p" | head -1)
        fi
    done

    echo "$current"
}

# 查询腾讯云证书列表
describe_certificates() {
    local domain="$1"

    log_info "查询腾讯云证书列表..."

    # 根据官方文档，DescribeCertificates 接口使用 SearchKey 参数进行域名模糊搜索
    # CertificateStatus 传 1 表示只查询"已通过"状态的证书
    # ExpirationSort 传 DESC 按过期时间降序，第一个结果即为最迟过期的证书
    # 参考: https://cloud.tencent.com/document/product/400/41671
    local payload="{\"SearchKey\":\"${domain}\",\"CertificateStatus\":[1],\"ExpirationSort\":\"DESC\",\"Limit\":10,\"Offset\":0}"
    local response=$(tccloud_api "DescribeCertificates" "$payload")

    # 打印原始响应用于调试（仅在 verbose 模式输出）
    log_debug "API响应: ${response:0:500}..."

    # 检查响应是否有错误
    if echo "$response" | grep -q '"Error"'; then
        local err_code=$(echo "$response" | sed -n 's/.*"Code"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        local err_msg=$(echo "$response" | sed -n 's/.*"Message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        log_error "API错误: ${err_code} - ${err_msg}"
        echo ""
        return
    fi

    # 检查是否有效响应
    if ! echo "$response" | grep -q '"Response"'; then
        log_error "API响应格式错误"
        echo ""
        return
    fi

    # 提取第一个有效证书的 CertificateId、CertEndTime 和 Status
    local cert_id=""
    local cert_end_time=""
    local cert_status=""

    # 优先使用 python3 解析 JSON，更可靠
    if command -v python3 &>/dev/null; then
        cert_id=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); certs=d.get('Response',{}).get('Certificates',[]); print(certs[0].get('CertificateId','')) if certs else print('')" 2>/dev/null)
        cert_end_time=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); certs=d.get('Response',{}).get('Certificates',[]); print(certs[0].get('CertEndTime','')) if certs else print('')" 2>/dev/null)
        cert_status=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); certs=d.get('Response',{}).get('Certificates',[]); print(certs[0].get('Status','')) if certs else print('')" 2>/dev/null)
    else
        # 回退到 sed 解析（字段顺序无关）
        local first_cert=$(echo "$response" | sed -n 's/.*"Certificates"[[:space:]]*:[[:space:]]*\[[[:space:]]*\({[^{}]*}\).*/\1/p' | head -1)
        cert_id=$(echo "$first_cert" | sed -n 's/.*"CertificateId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        cert_end_time=$(echo "$first_cert" | sed -n 's/.*"CertEndTime"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        cert_status=$(echo "$first_cert" | sed -n 's/.*"Status"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
    fi

    if [[ -z "$cert_id" ]] || [[ -z "$cert_end_time" ]]; then
        log_warn "未找到证书或证书过期时间"
        echo ""
        return
    fi

    log_info "查询到证书 ID: ${cert_id}, 状态: ${cert_status}, 过期时间: ${cert_end_time}"

    # 返回简化的JSON格式
    echo "{\"CertificateId\":\"${cert_id}\",\"CertEndTime\":\"${cert_end_time}\",\"Status\":${cert_status:-0}}"
}

# 获取腾讯云证书内容（使用 DescribeCertificateDetail 接口，限制比 DownloadCertificate 更少）
fetch_certificate() {
    local cert_id="$1"

    log_info "获取腾讯云证书内容..."

    local payload="{\"CertificateId\":\"${cert_id}\"}"
    local response=$(tccloud_api "DescribeCertificateDetail" "$payload")

    log_debug "DescribeCertificateDetail 原始响应前 800 字节: ${response:0:800}..."

    # 检查响应是否有错误
    if json_has_key "$response" "Error"; then
        local err_code=$(json_get_string "$response" "Code")
        local err_msg=$(json_get_string "$response" "Message")
        log_error "API错误: ${err_code} - ${err_msg}"
        return 1
    fi

    # 提取公钥和私钥（优先使用 python3 解析长文本更可靠）
    local cert_pub=""
    local cert_key=""

    if command -v python3 &>/dev/null; then
        cert_pub=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Response',{}).get('CertificatePublicKey',''))" 2>/dev/null)
        cert_key=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Response',{}).get('CertificatePrivateKey',''))" 2>/dev/null)
    else
        cert_pub=$(json_get_string "$response" "CertificatePublicKey")
        cert_key=$(json_get_string "$response" "CertificatePrivateKey")
    fi

    if [[ -n "$cert_pub" ]] && [[ -n "$cert_key" ]]; then
        echo "${cert_pub}"
        echo "${cert_key}"
        return 0
    else
        log_warn "证书公钥或私钥为空，可能证书状态未通过审核或无法读取"
        return 1
    fi
}

# 分离full chain证书中的公钥和私钥
split_full_chain_cert() {
    local content="$1"

    # 公钥是第一部分（服务器证书 + 中间证书）
    local cert_pub=$(echo "$content" | sed -n '/-----BEGIN CERTIFICATE-----/,$p' | sed -n '/-----BEGIN.*PRIVATE KEY-----/!p')
    # 私钥是第二部分（支持 RSA/EC/PKCS#8 等各种私钥格式）
    local cert_key=$(echo "$content" | sed -n '/-----BEGIN.*PRIVATE KEY-----/,$p')

    CERT_PUB="$cert_pub"
    CERT_KEY="$cert_key"
}

# 确保配置目录存在
ensure_config_dir() {
    local config_dir=$(dirname "$CONFIG_FILE")
    if [[ ! -d "$config_dir" ]]; then
        mkdir -p "$config_dir"
    fi
}

# 加载配置文件
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        cat "$CONFIG_FILE"
    else
        echo "[]"
    fi
}

# 保存配置到 JSON 文件（按 domain 去重，已存在则更新）
save_config() {
    local domain="$1"
    local cert_file="$2"
    local key_file="$3"
    local restart_cmd="$4"
    local secret_id="$5"
    local secret_key="$6"
    local region="$7"

    ensure_config_dir

    local config_json
    config_json=$(load_config)

    local new_entry
    new_entry=$(python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
except:
    d=[]
entry={
    'domain':'$domain',
    'cert_file':'$cert_file',
    'key_file':'$key_file',
    'restart_cmd':'$restart_cmd',
    'secret_id':'$secret_id',
    'secret_key':'$secret_key',
    'region':'${region:-ap-guangzhou}'
}
found=False
for i,item in enumerate(d):
    if item.get('domain')=='$domain':
        d[i]=entry
        found=True
        break
if not found:
    d.append(entry)
print(json.dumps(d,indent=2,ensure_ascii=False))
" <<< "$config_json" 2>/dev/null)

    if [[ -n "$new_entry" ]]; then
        printf '%s\n' "$new_entry" > "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        log_info "配置已保存到: $CONFIG_FILE"
    else
        log_warn "配置保存失败（python3 可能不可用）"
    fi
}

# 检查并添加 crontab 定时任务
setup_crontab() {
    local script_path
    script_path=$(readlink -f "$0")

    local cron_line="0 2 * * * ${script_path} --cron >> /var/log/tcssl_deploy_cron.log 2>&1"

    # 检查是否已存在相同任务
    local current_crontab
    current_crontab=$(crontab -l 2>/dev/null || true)
    if echo "$current_crontab" | grep -qF "${script_path} --cron"; then
        log_info "crontab 任务已存在，跳过添加"
        return 0
    fi

    log_info "正在添加 crontab 定时任务: 每天 02:00 执行"
    (echo "$current_crontab"; echo "$cron_line") | crontab -
    log_info "crontab 添加成功"
}

# 核心同步逻辑：查询并部署单个域名的证书
# 返回 0 表示成功部署或无需更新，返回 1 表示失败
sync_certificate() {
    local domain="$1"
    local cert_file="$2"
    local key_file="$3"
    local restart_cmd="$4"
    local force="$5"
    local no_backup="$6"

    log_info "========== 处理证书: $domain =========="

    # 查询腾讯云证书（最迟过期的已通过证书）
    local cloud_cert
    cloud_cert=$(describe_certificates "$domain")

    if [[ -z "$cloud_cert" ]]; then
        log_warn "腾讯云上未找到域名 $domain 的有效证书"
        return 1
    fi

    # 解析腾讯云证书信息
    local cloud_expiry_str
    cloud_expiry_str=$(echo "$cloud_cert" | sed -n 's/.*"CertEndTime"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    local cloud_cert_id
    cloud_cert_id=$(echo "$cloud_cert" | sed -n 's/.*"CertificateId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)

    if [[ -z "$cloud_expiry_str" ]]; then
        log_error "无法获取腾讯云证书过期时间"
        return 1
    fi

    log_info "腾讯云证书过期时间: $cloud_expiry_str"
    log_info "腾讯云证书ID: $cloud_cert_id"

    # 强制更新模式
    if [[ -n "$force" ]]; then
        log_info "强制更新模式，直接部署..."
        deploy_certificate "$cloud_cert_id" "$cert_file" "$key_file" "$restart_cmd" "$no_backup"
        return 0
    fi

    # 首次部署（本地证书不存在）
    if [[ ! -f "$cert_file" ]] || [[ ! -f "$key_file" ]]; then
        log_info "本地证书文件不存在，执行首次部署..."
        deploy_certificate "$cloud_cert_id" "$cert_file" "$key_file" "$restart_cmd" "$no_backup"
        return 0
    fi

    # 获取本地证书过期时间
    log_info "获取本地证书过期时间..."
    local local_expiry_str
    local_expiry_str=$(extract_expiry_from_cert "$cert_file")
    if [[ -z "$local_expiry_str" ]]; then
        log_error "无法读取本地证书过期时间"
        return 1
    fi
    local local_expiry_ts
    local_expiry_ts=$(date_to_timestamp "$local_expiry_str")
    log_info "本地证书过期时间: $local_expiry_str"

    # 转换腾讯云证书过期时间为时间戳
    local cloud_expiry_ts
    cloud_expiry_ts=$(date -d "${cloud_expiry_str}" +%s 2>/dev/null)

    # 对比过期时间
    log_info "过期时间对比: 本地 $local_expiry_str vs 云端 $cloud_expiry_str"

    # 判断是否需要更新
    if [[ $cloud_expiry_ts -gt $local_expiry_ts ]]; then
        local diff_days=$(( (cloud_expiry_ts - local_expiry_ts) / 86400 ))
        log_info "腾讯云证书更新，较本地证书新 $diff_days 天，开始同步..."
        deploy_certificate "$cloud_cert_id" "$cert_file" "$key_file" "$restart_cmd" "$no_backup"
        return 0
    else
        log_info "本地证书已是最新，无需更新"
        return 0
    fi
}

# 计划任务模式：读取配置批量处理
run_cron_mode() {
    # 输出时间戳（含时区）
    echo "========================================"
    echo "TcSslDeploy Cron 执行时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "========================================"
    echo

    local config_json
    config_json=$(load_config)

    local count
    count=$(echo "$config_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)

    if [[ -z "$count" ]] || [[ "$count" -eq 0 ]]; then
        log_error "配置文件为空，没有需要检查的证书"
        log_error "请先手动运行脚本成功部署至少一个证书"
        exit 1
    fi

    log_info "计划任务模式：共 $count 个证书需要检查"

    local i
    for ((i=0; i<count; i++)); do
        local item
        item=$(echo "$config_json" | python3 -c "import sys,json; d=json.load(sys.stdin); import json as j; print(j.dumps(d[$i]))" 2>/dev/null)

        local domain cert_file key_file restart_cmd secret_id secret_key region
        domain=$(echo "$item" | python3 -c "import sys,json; print(json.load(sys.stdin).get('domain',''))" 2>/dev/null)
        cert_file=$(echo "$item" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cert_file',''))" 2>/dev/null)
        key_file=$(echo "$item" | python3 -c "import sys,json; print(json.load(sys.stdin).get('key_file',''))" 2>/dev/null)
        restart_cmd=$(echo "$item" | python3 -c "import sys,json; print(json.load(sys.stdin).get('restart_cmd',''))" 2>/dev/null)
        secret_id=$(echo "$item" | python3 -c "import sys,json; print(json.load(sys.stdin).get('secret_id',''))" 2>/dev/null)
        secret_key=$(echo "$item" | python3 -c "import sys,json; print(json.load(sys.stdin).get('secret_key',''))" 2>/dev/null)
        region=$(echo "$item" | python3 -c "import sys,json; print(json.load(sys.stdin).get('region','ap-guangzhou'))" 2>/dev/null)

        if [[ -z "$domain" ]] || [[ -z "$cert_file" ]] || [[ -z "$key_file" ]] || [[ -z "$secret_id" ]] || [[ -z "$secret_key" ]]; then
            log_error "[$((i+1))/$count] 配置项不完整，跳过: $domain"
            continue
        fi

        # 设置环境变量供 API 调用使用
        export TENCENTCLOUD_SECRET_ID="$secret_id"
        export TENCENTCLOUD_SECRET_KEY="$secret_key"
        export TENCENTCLOUD_REGION="$region"

        # 执行同步（cron 模式下不强制更新，不保留备份）
        if ! sync_certificate "$domain" "$cert_file" "$key_file" "$restart_cmd" "" "1"; then
            log_error "[$((i+1))/$count] 证书处理失败: $domain"
        fi
    done

    log_info "========== 计划任务执行完毕 =========="
}

# 部署证书到本地路径的通用函数
deploy_certificate() {
    local cert_id="$1"
    local cert_file="$2"
    local key_file="$3"
    local restart_cmd="$4"
    local no_backup="$5"

    # 获取证书内容
    local cert_content
    cert_content=$(fetch_certificate "$cert_id")

    if [[ -z "$cert_content" ]]; then
        log_error "获取腾讯云证书内容失败"
        exit 1
    fi

    log_info "证书内容长度: ${#cert_content} 字节"

    # 分离公钥和私钥（支持 RSA/EC/PKCS#8 等各种私钥格式）
    local cert_pub=$(echo "$cert_content" | sed -n '1,/-----BEGIN.*PRIVATE KEY-----/p' | head -n -1)
    local cert_key=$(echo "$cert_content" | sed -n '/-----BEGIN.*PRIVATE KEY-----/,$p')

    log_info "提取公钥长度: ${#cert_pub} 字节, 私钥长度: ${#cert_key} 字节"

    if [[ -z "$cert_pub" ]] || [[ -z "$cert_key" ]]; then
        log_error "无法从获取内容中分离出有效的公钥或私钥"
        exit 1
    fi

    # 确保目标目录存在
    local cert_dir=$(dirname "$cert_file")
    local key_dir=$(dirname "$key_file")
    if [[ ! -d "$cert_dir" ]]; then
        log_info "创建证书目录: $cert_dir"
        mkdir -p "$cert_dir"
    fi
    if [[ ! -d "$key_dir" ]]; then
        log_info "创建私钥目录: $key_dir"
        mkdir -p "$key_dir"
    fi

    # 备份原文件（如果存在且未指定 --no-backup）
    if [[ -z "$no_backup" ]]; then
        local backup_suffix=$(date +%Y%m%d%H%M%S)
        if [[ -f "$cert_file" ]]; then
            log_info "备份原证书文件..."
            cp "$cert_file" "${cert_file}.bak.${backup_suffix}"
        fi
        if [[ -f "$key_file" ]]; then
            log_info "备份原私钥文件..."
            cp "$key_file" "${key_file}.bak.${backup_suffix}"
        fi
    fi

    # 写入新证书（使用 printf 避免 echo 对特殊字符的处理）
    log_info "更新证书文件..."
    printf '%s\n' "$cert_pub" > "$cert_file"
    printf '%s\n' "$cert_key" > "$key_file"

    # 设置文件权限
    chmod 600 "$key_file"
    chmod 644 "$cert_file"

    log_info "证书文件已更新:"
    log_info "  公钥: $cert_file"
    log_info "  私钥: $key_file"

    # 执行重启命令
    if [[ -n "$restart_cmd" ]]; then
        log_info "执行重启命令: $restart_cmd"
        if eval "$restart_cmd"; then
            log_info "服务重启成功"
        else
            log_error "服务重启失败"
            exit 1
        fi
    fi

    log_info "========== 证书同步完成 =========="
}

# 主函数
main() {
    parse_args "$@"

    # 测试模式
    if [[ -n "$TEST_MODE" ]]; then
        test_api_key
        exit $?
    fi

    # 计划任务模式
    if [[ -n "$CRON_MODE" ]]; then
        run_cron_mode
        exit 0
    fi

    validate_args

    log_info "========== 腾讯云SSL证书同步开始 =========="
    log_info "证书文件: $CERT_FILE"
    log_info "私钥文件: $KEY_FILE"

    # 确定域名
    if [[ -z "$DOMAIN" ]]; then
        if [[ -f "$CERT_FILE" ]]; then
            log_info "未指定域名，从本地证书中提取..."
            DOMAIN=$(extract_domain_from_cert "$CERT_FILE")
            if [[ -z "$DOMAIN" ]]; then
                log_error "无法从证书中提取域名，请使用 -d 参数指定"
                exit 1
            fi
            log_info "提取到域名: $DOMAIN"
        else
            log_error "本地证书文件不存在且未指定域名，请使用 -d 参数指定域名"
            exit 1
        fi
    else
        log_info "使用指定域名: $DOMAIN"
    fi

    # 执行同步
    if sync_certificate "$DOMAIN" "$CERT_FILE" "$KEY_FILE" "$RESTART_CMD" "$FORCE_UPDATE" "$NO_BACKUP"; then
        # 同步成功，保存配置到 JSON 文件
        save_config "$DOMAIN" "$CERT_FILE" "$KEY_FILE" "$RESTART_CMD" \
            "$TENCENTCLOUD_SECRET_ID" "$TENCENTCLOUD_SECRET_KEY" "${TENCENTCLOUD_REGION:-ap-guangzhou}"

        # 自动添加 crontab（如果尚未添加）
        setup_crontab
    fi
}

# 运行主函数
main "$@"
