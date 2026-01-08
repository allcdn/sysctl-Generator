#!/bin/bash
# ============================================================================
# 面向容器和物理机的自动 sysctl.conf 优化生成器
# 自动检测硬件并生成调优的 sysctl 参数
# Version 1.1.0
# ============================================================================

set -e

OUTPUT_FILE="$HOME/sysctl-suggestion.conf"
DISABLE_IPV6=false
IS_CONTAINER=false
CONTAINER_TYPE="unknown"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # 无颜色

# ============================================================================
# 使用场景描述和函数
# ============================================================================

print_banner() {
    clear
    echo -e "${BLUE}${BOLD}"
    echo "                        _    _   _____                                 _               "
    echo "                       | |  | | |  __ \                               | |              "
    echo " ___  _   _  ___   ___ | |_ | | | |  \/  ___  _ __    ___  _ __  __ _ | |_  ___   _ __ "
    echo "/ __|| | | |/ __| / __|| __|| | | | __  / _ \| '_ \  / _ \| '__|/ _\` || __|/ _ \ | '__|"
    echo "\__ \| |_| |\__ \| (__ | |_ | | | |_\ \|  __/| | | ||  __/| |  | (_| || |_| (_) || |   "
    echo "|___/ \__, ||___/ \___| \__||_|  \____/ \___||_| |_| \___||_|   \__,_| \__|\___/ |_|   "
    echo "       __/ |                                                                            "
    echo "      |___/                                                                             "
    echo -e "${NC}"
    echo -e "${CYAN}自动 sysctl.conf 优化器${NC}"
    echo -e "分析您的系统并生成优化的内核参数\n"
    echo -e "${YELLOW}GitHub:${NC} https://github.com/ENGINYRING/sysctl-Generator"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}ENGINYRING${NC} - ${CYAN}高性能网站托管和 VPS 服务${NC}"
    echo -e "为您的应用程序优化基础设施 - ${BOLD}www.enginyring.com${NC}\n"
}

# 定义使用场景及其描述
declare -A USE_CASES
USE_CASES=(
    ["general"]="通用用途：混合工作负载的平衡调优"
    ["virtualization"]="虚拟化主机：适用于 KVM/QEMU/Proxmox/ESXi 等"
    ["web"]="Web 服务器：针对 HTTP 流量优化"
    ["database"]="数据库服务器：针对 MySQL/PostgreSQL 等调优"
    ["cache"]="缓存服务器：适用于 Redis/Memcached 等"
    ["compute"]="HPC/计算节点：适用于计算工作负载"
    ["fileserver"]="文件服务器：适用于 NFS/SMB/文件存储"
    ["network"]="网络设备：适用于路由器/防火墙/网关"
    ["容器"]="容器主机：适用于 Docker/Kubernetes 节点"
    ["development"]="开发机器：适用于编码工作站"
)

# ============================================================================
# 容器检测函数
# ============================================================================

detect_容器() {
    # 检查常见的容器指示器
    if [ -f /.dockerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
        IS_CONTAINER=true
        CONTAINER_TYPE="docker"
    elif grep -q -E '/(lxc|docker)/' /proc/1/cgroup 2>/dev/null; then
        IS_CONTAINER=true
        if grep -q lxc /proc/1/cgroup; then
            CONTAINER_TYPE="lxc"
        else
            CONTAINER_TYPE="docker"
        fi
    elif [ -f /run/.容器env ]; then
        IS_CONTAINER=true
        CONTAINER_TYPE="podman"
    fi

    if $IS_CONTAINER; then
        echo -e "${YELLOW}运行在 ${CONTAINER_TYPE} 容器环境中${NC}"
        echo -e "${YELLOW}注意：将应用容器特定的优化${NC}\n"
    fi
}

# ============================================================================
# 硬件检测函数
# ============================================================================

detect_os() {
    if [ -f /etc/redhat-release ] || [ -f /etc/centos-release ] || [ -f /etc/fedora-release ]; then
        OS="rhel"
        INSTALL_PATH="/etc/sysctl.d/99-custom.conf"
    else
        OS="deb"
        INSTALL_PATH="/etc/sysctl.conf"
    fi
}

detect_cpu() {
    # 始终使用 nproc，它遵守 cgroup/cpuset CPU 限制（适用于 Docker、LXC 和物理机）
    if command -v nproc >/dev/null 2>&1; then
        CORES=$(nproc)
        THREADS=$CORES
        echo -e "CPU： ${GREEN}${CORES}${NC} 核心 / ${GREEN}${THREADS}${NC} 线程"
        return
    fi

    # 回退方案：从 /proc/cpuinfo 统计处理器数
    CORES=$(grep -c ^processor /proc/cpuinfo)
    THREADS=$CORES
    echo -e "CPU： ${GREEN}${CORES}${NC} 核心 / ${GREEN}${THREADS}${NC} 线程 (回退)"
}

detect_ram() {
    # 对于容器，优先检查 cgroup 内存限制
    if $IS_CONTAINER; then
        local mem_limit=""
        
        if [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
            # cgroups v1
            mem_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
        elif [ -f /sys/fs/cgroup/memory.max ]; then
            # cgroups v2
            mem_limit=$(cat /sys/fs/cgroup/memory.max)
        fi
        
        # 如果存在有效限制且不是最大值
        if [[ -n "$mem_limit" && "$mem_limit" != "max" && "$mem_limit" != "9223372036854771712" ]]; then
            # 将字节转换为 GB
            RAM=$(( mem_limit / 1024 / 1024 / 1024 ))
            if [ "$RAM" -eq 0 ]; then
                # 如果小于 1GB，向上取整为 1
                RAM=1
            fi
            echo -e "容器内存限制： ${GREEN}${RAM}${NC} GB"
            return
        fi
    fi

    # 从 /proc/meminfo 进行常规检测，适用于容器和非容器
    local mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    
    # 不使用 bc 计算 RAM（GB）
    if command -v bc >/dev/null 2>&1; then
        # 如果 bc 可用，使用它进行精确计算
        RAM=$(echo "scale=1; $mem_kb / 1024 / 1024" | bc)
        # 为简单起见，向上取整到最近的整数
        RAM=$(echo "($RAM+0.5)/1" | bc)
    else
        # 不使用 bc 的替代计算（不太精确但可用）
        RAM=$(( mem_kb / 1024 / 1024 ))
        # 如果需要，加 1 向上取整
        if [[ $mem_kb -gt $(( RAM * 1024 * 1024 )) ]]; then
            RAM=$(( RAM + 1 ))
        fi
    fi
    
    # 检测失败时的回退方案
    if [[ -z "$RAM" || "$RAM" -eq 0 ]]; then
        RAM=1
    fi
    
    echo -e "内存： ${GREEN}${RAM}${NC} GB"
}

detect_nic_speed() {
    # 初始化网卡速度为默认 1000 Mbps
    NIC=1000

    # 查找活动的网络接口
    if command -v ip >/dev/null 2>&1; then
        ACTIVE_IF=$(ip -o route get 1 | awk '{print $5; exit}')
    else
        ACTIVE_IF=$(route -n | grep "^0.0.0.0" | head -1 | awk '{print $8}')
    fi

    # 如果未找到活动接口，尝试获取第一个非回环接口
    if [[ -z "$ACTIVE_IF" || "$ACTIVE_IF" == "lo" ]]; then
        ACTIVE_IF=$(ip -o link show | grep -v "link/loopback" | awk -F': ' '{print $2; exit}')
    fi

    # 如果可用，使用 ethtool 获取速度
    if [[ -n "$ACTIVE_IF" ]] && command -v ethtool >/dev/null 2>&1; then
        local SPEED=$(ethtool $ACTIVE_IF 2>/dev/null | grep "Speed:" | awk '{print $2}' | sed 's/[^0-9]//g')
        if [[ -n "$SPEED" && "$SPEED" -gt 0 ]]; then
            NIC=$SPEED
        fi
    fi

    # 从 /sys 文件系统检查速度
    if [[ -n "$ACTIVE_IF" && -f "/sys/class/net/$ACTIVE_IF/speed" ]]; then
        local SPEED=$(cat "/sys/class/net/$ACTIVE_IF/speed" 2>/dev/null)
        if [[ -n "$SPEED" && "$SPEED" -gt 0 ]]; then
            NIC=$SPEED
        fi
    fi
    
    # For 容器s, we can't reliably determine network speed limitations
    # 因此，如果我们在容器中，添加注释're in a 容器, add a note
    if $IS_CONTAINER; then
        echo -e "网络： ${GREEN}${NIC}${NC} Mbps (${ACTIVE_IF}) ${YELLOW}[容器共享网络]${NC}"
    else
        echo -e "网络： ${GREEN}${NIC}${NC} Mbps (${ACTIVE_IF})"
    fi
}

detect_disk_type() {
    # 默认为 HDD
    DISK_TYPE="hdd"
    
    # In 容器s, disk is usually the host's, but often limited by I/O controls
    if $IS_CONTAINER; then
        # 检查 cgroups 中的 IO 限制
        local has_io_limits=false
        if [ -d /sys/fs/cgroup/blkio ] || [ -f /sys/fs/cgroup/io.max ]; then
            has_io_limits=true
        fi
        
        # Check if it's likely a cloud 容器 (which typically have SSD backends)
        if grep -q "^Amazon\|^Google\|^Azure\|^Digital Ocean" /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null; then
            DISK_TYPE="ssd"
        fi
        
        local DISK_TYPE_FRIENDLY="主机系统存储"
        if [[ "$DISK_TYPE" == "ssd" ]]; then
            DISK_TYPE_FRIENDLY="主机系统 SSD（可能）"
        fi
        
        if $has_io_limits; then
            echo -e "磁盘： ${GREEN}${DISK_TYPE_FRIENDLY}${NC} ${YELLOW}[检测到 I/O 限制]${NC}"
        else
            echo -e "磁盘： ${GREEN}${DISK_TYPE_FRIENDLY}${NC} ${YELLOW}[与主机共享]${NC}"
        fi
        return
    fi
    
    # 非容器的常规磁盘检测
    # 尝试查找系统磁盘
    ROOT_DEVICE=$(df / | grep -v Filesystem | awk '{print $1}' | sed -E 's/\/dev\/(sd[a-z]|nvme[0-9]+n[0-9]+|xvd[a-z]|vd[a-z]).*/\1/')
    
    # Check if it's NVMe
    if [[ "$ROOT_DEVICE" == nvme* ]]; then
        DISK_TYPE="nvme"
    else
        # 使用 lsblk 或旋转标志检查是否为 SSD
        if command -v lsblk >/dev/null 2>&1; then
            # 检查 rotational = 0（SSD）
            local ROTATIONAL
            if [[ -n "$ROOT_DEVICE" ]]; then
                ROTATIONAL=$(lsblk -d -o name,rota | grep "$ROOT_DEVICE" | awk '{print $2}')
            else
                # 只检查第一个磁盘
                ROTATIONAL=$(lsblk -d -o name,rota | grep -v NAME | head -1 | awk '{print $2}')
            fi
            
            if [[ "$ROTATIONAL" == "0" ]]; then
                DISK_TYPE="ssd"
            fi
        elif [[ -n "$ROOT_DEVICE" && -f "/sys/block/$ROOT_DEVICE/queue/rotational" ]]; then
            # 直接在 sysfs 中检查
            local ROTATIONAL=$(cat "/sys/block/$ROOT_DEVICE/queue/rotational")
            if [[ "$ROTATIONAL" == "0" ]]; then
                DISK_TYPE="ssd"
            fi
        fi
    fi
    
    local DISK_TYPE_FRIENDLY="硬盘驱动器 (HDD)"
    if [[ "$DISK_TYPE" == "ssd" ]]; then
        DISK_TYPE_FRIENDLY="固态硬盘 (SSD)"
    elif [[ "$DISK_TYPE" == "nvme" ]]; then
        DISK_TYPE_FRIENDLY="NVMe 固态硬盘"
    fi
    
    echo -e "磁盘： ${GREEN}${DISK_TYPE_FRIENDLY}${NC}"
}

confirm_or_input_hardware() {
    echo -e "\n${BLUE}${BOLD}硬件参数：${NC}"
    echo -e "当前检测到的值："
    echo -e "  1. CPU： ${GREEN}${CORES}${NC} 核心 / ${GREEN}${THREADS}${NC} 线程"
    echo -e "  2. 内存： ${GREEN}${RAM}${NC} GB"
    echo -e "  3. 网络： ${GREEN}${NIC}${NC} Mbps"
    echo -e "  4. 磁盘： ${GREEN}$(if [[ "$DISK_TYPE" == "ssd" ]]; then echo "SSD"; elif [[ "$DISK_TYPE" == "nvme" ]]; then echo "NVMe"; else echo "HDD"; fi)${NC}"
    
    echo -e "\n您想使用这些检测到的值还是手动输入自己的值？"
    echo "1) 使用检测到的值（默认）"
    echo "2) 手动输入值"
    
    local selection
    while true; do
        echo -ne "\n输入选择 [1-2]: "
        read selection
        
        if [[ "$selection" == "1" || "$selection" == "" ]]; then
            echo -e "使用检测到的硬件值。"
            break
        elif [[ "$selection" == "2" ]]; then
            # CPU 输入
            while true; do
                echo -ne "\n输入 CPU 核心数： "
                read input_cores
                if [[ "$input_cores" =~ ^[0-9]+$ && "$input_cores" -gt 0 ]]; then
                    CORES=$input_cores
                    break
                else
                    echo -e "${RED}输入无效。请输入正数。${NC}"
                fi
            done
            
            while true; do
                echo -ne "Enter number of CPU 线程: "
                read input_线程
                if [[ "$input_线程" =~ ^[0-9]+$ && "$input_线程" -gt 0 ]]; then
                    THREADS=$input_线程
                    break
                else
                    echo -e "${RED}输入无效。请输入正数。${NC}"
                fi
            done
            
            # 内存输入
            while true; do
                echo -ne "\n输入内存大小（GB）： "
                read input_ram
                if [[ "$input_ram" =~ ^[0-9]+$ && "$input_ram" -gt 0 ]]; then
                    RAM=$input_ram
                    break
                else
                    echo -e "${RED}输入无效。请输入正数。${NC}"
                fi
            done
            
            # 网络速度输入
            while true; do
                echo -ne "\n输入网络速度（Mbps）（例如，1000 表示 1Gbps）： "
                read input_nic
                if [[ "$input_nic" =~ ^[0-9]+$ && "$input_nic" -gt 0 ]]; then
                    NIC=$input_nic
                    break
                else
                    echo -e "${RED}输入无效。请输入正数。${NC}"
                fi
            done
            
            # 磁盘类型输入
            echo -e "\n选择磁盘类型："
            echo "1) HDD (Hard Disk Drive)"
            echo "2) SSD (Solid State Drive)"
            echo "3) NVMe 固态硬盘"
            
            while true; do
                echo -ne "\n输入选择 [1-3]: "
                read disk_selection
                
                if [[ "$disk_selection" == "1" ]]; then
                    DISK_TYPE="hdd"
                    break
                elif [[ "$disk_selection" == "2" ]]; then
                    DISK_TYPE="ssd"
                    break
                elif [[ "$disk_selection" == "3" ]]; then
                    DISK_TYPE="nvme"
                    break
                else
                    echo -e "${RED}选择无效。请重试。${NC}"
                fi
            done
            
            echo -e "\n${GREEN}硬件参数已更新：${NC}"
            echo -e "  - CPU： ${CORES} 核心 / ${THREADS} 线程"
            echo -e "  - 内存： ${RAM} GB"
            echo -e "  - 网络： ${NIC} Mbps"
            echo -e "  - 磁盘： $(if [[ "$DISK_TYPE" == "ssd" ]]; then echo "SSD"; elif [[ "$DISK_TYPE" == "nvme" ]]; then echo "NVMe"; else echo "HDD"; fi)"
            break
        else
            echo -e "${RED}选择无效。请重试。${NC}"
        fi
    done
}

get_use_case() {
    echo -e "\n${BLUE}${BOLD}Select your server's primary use case:${NC}"
    echo -e "这将决定使用哪个优化配置文件。\n"
    
    local i=1
    local keys=()
    for key in "${!USE_CASES[@]}"; do
        keys[$i]=$key
        printf "%2d) ${YELLOW}%-20s${NC} %s\n" $i "${key}" "${USE_CASES[$key]}"
        ((i++))
    done
    
    local selection
    while true; do
        echo -ne "\n输入选择 [1-$((i-1))]: "
        read selection
        
        if [[ "$selection" =~ ^[0-9]+$ && "$selection" -ge 1 && "$selection" -lt "$i" ]]; then
            USE_CASE="${keys[$selection]}"
            break
        else
            echo -e "${RED}选择无效。请重试。${NC}"
        fi
    done
    
    echo -e "\n已选择： ${YELLOW}${USE_CASE}${NC} - ${USE_CASES[$USE_CASE]}"
}

ask_ipv6() {
    echo -e "\n${BLUE}${BOLD}IPv6 配置：${NC}"
    echo -e "您想在此系统上禁用 IPv6 吗？\n"
    echo "1) 否，保持 IPv6 启用（默认）"
    echo "2) 是，完全禁用 IPv6"
    
    local selection
    while true; do
        echo -ne "\n输入选择 [1-2]: "
        read selection
        
        if [[ "$selection" == "1" || "$selection" == "" ]]; then
            DISABLE_IPV6=false
            break
        elif [[ "$selection" == "2" ]]; then
            DISABLE_IPV6=true
            break
        else
            echo -e "${RED}选择无效。请重试。${NC}"
        fi
    done
    
    if $DISABLE_IPV6; then
        echo -e "IPv6 将被 ${RED}禁用${NC} 在生成的配置中。"
    else
        echo -e "IPv6 将被 ${GREEN}启用${NC} 在生成的配置中。"
    fi
}

confirm_selection() {
    local disk_type_name="HDD"
    [[ "$DISK_TYPE" == "ssd" ]] && disk_type_name="SSD" 
    [[ "$DISK_TYPE" == "nvme" ]] && disk_type_name="NVMe"
    
    echo -e "\n${BLUE}${BOLD}配置摘要：${NC}"
    echo -e "  - 使用场景： ${YELLOW}${USE_CASE}${NC} (${USE_CASES[$USE_CASE]})"
    echo -e "  - CPU： ${CORES} 核心 / ${THREADS} 线程"
    echo -e "  - 内存： ${RAM} GB"
    echo -e "  - 网络： ${NIC} Mbps"
    echo -e "  - 磁盘： ${disk_type_name}"
    if $IS_CONTAINER; then
        echo -e "  - 环境： ${CONTAINER_TYPE} 容器"
    fi
    echo -e "  - IPv6: $(if $DISABLE_IPV6; then echo "${RED}Disabled${NC}"; else echo "${GREEN}Enabled${NC}"; fi)"
    echo -e "  - 输出文件： ${OUTPUT_FILE}"
    
    while true; do
        echo -ne "\n使用这些设置生成 sysctl.conf？ [Y/n]: "
        read confirmation
        
        if [[ "$confirmation" == "" || "$confirmation" == "y" || "$confirmation" == "Y" ]]; then
            return 0
        elif [[ "$confirmation" == "n" || "$confirmation" == "N" ]]; then
            echo -e "${RED}已被用户中止。${NC}"
            exit 0
        else
            echo -e "${RED}选择无效。请输入 Y 或 n。${NC}"
        fi
    done
}

# ============================================================================
# sysctl.conf 生成函数
# ============================================================================

generate_sysctl_conf() {
    # 计算派生值
    local swappiness=10
    local dirty_ratio=10
    local dirty_bg=5
    local min_free_kb
    local nr_hugepages

    # 根据磁盘类型调整值
    if [[ "$DISK_TYPE" == "ssd" || "$DISK_TYPE" == "nvme" ]]; then
        swappiness=5
    fi

    # 根据内存调整值
    if (( RAM >= 16 )); then
        dirty_ratio=5
        dirty_bg=2
    fi

    # Calculate min_free_kb based on RAM (multiply by 4096)
    min_free_kb=$(( RAM * 4096 ))
    
    # Calculate nr_hugepages based on RAM
    nr_hugepages=$(( RAM * 156 ))

    # 基于网卡速度的网络缓冲区
    local rmax
    local wmax
    local opts

    if (( NIC >= 10000 )); then
        rmax=67108864
        wmax=67108864
        opts="4096 262144 33554432"
    elif (( NIC >= 1000 )); then
        rmax=16777216
        wmax=16777216
        opts="4096 262144 16777216"
    else
        rmax=4194304
        wmax=4194304
        opts="4096 131072 4194304"
    fi

    # 构建基准 sysctl 设置
    local all_settings=(
        "net.core.rmem_max = $rmax"
        "net.core.wmem_max = $wmax"
        "net.core.rmem_default = 2097152"
        "net.core.wmem_default = 2097152"
        "net.core.optmem_max = 4194304"
        "net.ipv4.tcp_rmem = $opts"
        "net.ipv4.tcp_wmem = $opts"
        "net.ipv4.udp_mem = 4194304 8388608 16777216"
        "net.ipv4.tcp_mem = 786432 1048576 26777216"
        "net.ipv4.udp_rmem_min = 16384"
        "net.ipv4.udp_wmem_min = 16384"
        "net.core.netdev_max_backlog = $(( NIC >= 10000 ? 250000 : 30000 ))"
        "net.core.somaxconn = $(( THREADS * 1024 ))"
        "net.ipv4.tcp_max_syn_backlog = 16384"
        "net.core.busy_poll = 50"
        "net.core.busy_read = 50"
        "net.ipv4.tcp_fastopen = 3"
        "net.ipv4.tcp_notsent_lowat = 16384"
        "net.core.netdev_budget_usecs = 4000"
        "net.core.dev_weight = 64"
        "net.ipv4.tcp_max_tw_buckets = 2000000"
        "net.ipv4.ip_local_port_range = 1024 65535"
        "net.ipv4.tcp_congestion_control = bbr"
        "net.core.default_qdisc = fq"
        "net.ipv4.tcp_window_scaling = 1"
        "net.ipv4.tcp_timestamps = 1"
        "net.ipv4.tcp_sack = 1"
        "net.ipv4.tcp_dsack = 1"
        "net.ipv4.tcp_slow_start_after_idle = 0"
        "net.ipv4.tcp_fin_timeout = 10"
        "net.ipv4.tcp_keepalive_time = 300"
        "net.ipv4.tcp_keepalive_intvl = 10"
        "net.ipv4.tcp_keepalive_probes = 6"
        "net.ipv4.tcp_moderate_rcvbuf = 1"
        "net.ipv4.tcp_frto = 2"
        "net.ipv4.tcp_mtu_probing = 1"
        "net.ipv4.conf.all.rp_filter = 1"
        "net.ipv4.conf.default.rp_filter = 1"
        "net.ipv4.conf.all.accept_redirects = 0"
        "net.ipv4.conf.default.accept_redirects = 0"
        "net.netfilter.nf_conntrack_max = 1048576"
        "kernel.sched_min_granularity_ns = 10000"
        "kernel.sched_wakeup_granularity_ns = 15000"
        "kernel.sched_latency_ns = 60000"
        "kernel.sched_rt_runtime_us = 980000"
        "kernel.sched_migration_cost_ns = 50000"
        "kernel.sched_autogroup_启用 = 0"
        "kernel.sched_cfs_bandwidth_slice_us = 3000"
        "vm.swappiness = $swappiness"
        "vm.dirty_ratio = $dirty_ratio"
        "vm.dirty_background_ratio = $dirty_bg"
        "vm.dirty_expire_centisecs = 1000"
        "vm.dirty_writeback_centisecs = 100"
        "vm.zone_reclaim_mode = 0"
        "vm.min_free_kbytes = $min_free_kb"
        "vm.vfs_cache_pressure = 50"
        "vm.overcommit_memory = 0"
        "vm.overcommit_ratio = 50"
        "vm.max_map_count = 1048576"
        "vm.page-cluster = 0"
        "vm.oom_kill_allocating_task = 1"
        "fs.file-max = 26214400"
        "fs.nr_open = 26214400"
        "fs.aio-max-nr = 1048576"
        "fs.inotify.max_user_instances = 8192"
        "fs.inotify.max_user_watches = 1048576"
        "kernel.pid_max = 4194304"
    )

    # 添加特定使用场景的设置
    declare -A extra_settings

    case "$USE_CASE" in
        "virtualization")
            # 网络缓冲区设置 - 针对虚拟机流量优化
            extra_settings["net.core.rmem_max"]=$(( NIC >= 25000 ? 134217728 : (NIC >= 10000 ? 67108864 : 33554432) ))
            extra_settings["net.core.wmem_max"]=$(( NIC >= 25000 ? 134217728 : (NIC >= 10000 ? 67108864 : 33554432) ))
            extra_settings["net.core.rmem_default"]=8388608
            extra_settings["net.core.wmem_default"]=8388608
            extra_settings["net.core.optmem_max"]=16777216
            
            # Fix TCP rmem and wmem settings using if/then/else instead of ternary operators for strings
            if [ "$NIC" -ge 25000 ]; then
                extra_settings["net.ipv4.tcp_rmem"]="8192 262144 134217728"
                extra_settings["net.ipv4.tcp_wmem"]="8192 262144 134217728"
            else
                extra_settings["net.ipv4.tcp_rmem"]="4096 131072 67108864"
                extra_settings["net.ipv4.tcp_wmem"]="4096 131072 67108864"
            fi
            
            extra_settings["net.ipv4.udp_mem"]="16777216 33554432 67108864"
            extra_settings["net.ipv4.tcp_mem"]="16777216 33554432 67108864"
            
            # 虚拟机流量的网络设置
            extra_settings["net.ipv4.ip_forward"]=1
            extra_settings["net.ipv6.conf.all.forwarding"]=1
            extra_settings["net.bridge.bridge-nf-call-iptables"]=0
            extra_settings["net.bridge.bridge-nf-call-ip6tables"]=0
            extra_settings["net.bridge.bridge-nf-call-arptables"]=0
            extra_settings["net.core.netdev_max_backlog"]=$(( NIC >= 10000 ? 250000 : 100000 ))
            extra_settings["net.core.somaxconn"]=$(( THREADS * 1024 < 65535 ? THREADS * 1024 : 65535 ))
            extra_settings["net.ipv4.tcp_max_syn_backlog"]=$(( THREADS * 1024 < 262144 ? (THREADS * 1024 > 16384 ? THREADS * 1024 : 16384) : 262144 ))
            extra_settings["net.ipv4.tcp_tw_reuse"]=1
            extra_settings["net.ipv4.tcp_fin_timeout"]=15
            
            # 虚拟机的内存设置
            extra_settings["vm.nr_hugepages"]=$(( RAM >= 128 ? RAM * 200 / (CORES + 1) : RAM * 156 / (CORES + 1) ))
            extra_settings["vm.nr_hugepages"]=$(( extra_settings["vm.nr_hugepages"] < 2 ? 2 : extra_settings["vm.nr_hugepages"] ))
            extra_settings["vm.hugetlb_shm_group"]=0
            extra_settings["vm.transparent_hugepage.启用"]="madvise"
            extra_settings["vm.transparent_hugepage.defrag"]=$(( RAM >= 64 ? "madvise" : "never" ))
            extra_settings["vm.swappiness"]=$(( DISK_TYPE == "ssd" || DISK_TYPE == "nvme" ? 5 : 10 ))
            extra_settings["vm.dirty_ratio"]=$(( RAM >= 64 ? 10 : (RAM >= 16 ? 20 : 30) ))
            extra_settings["vm.dirty_background_ratio"]=$(( RAM >= 64 ? 3 : (RAM >= 16 ? 5 : 10) ))
            extra_settings["vm.overcommit_memory"]=1
            extra_settings["vm.overcommit_ratio"]=$(( 50 + RAM / 8 < 95 ? 50 + RAM / 8 : 95 ))
            extra_settings["vm.zone_reclaim_mode"]=0
            extra_settings["vm.min_free_kbytes"]=$(( min_free_kb < RAM * 2048 ? RAM * 2048 : min_free_kb ))
            extra_settings["vm.vfs_cache_pressure"]=$(( RAM >= 64 ? 50 : 75 ))
            
            # 针对虚拟机优化的 CPU 调度器
            extra_settings["kernel.sched_migration_cost_ns"]=$(( CORES <= 4 ? 1000000 : 5000000 ))
            extra_settings["kernel.sched_autogroup_启用"]=0
            extra_settings["kernel.pid_max"]=$(( RAM * 16384 < 4194304 * 2 ? RAM * 16384 : 4194304 * 2 ))
            
            # 根据内存扩展连接跟踪
            extra_settings["net.netfilter.nf_conntrack_max"]=$(( RAM * 16384 < 4194304 ? RAM * 16384 : 4194304 ))
            extra_settings["net.netfilter.nf_conntrack_tcp_timeout_established"]=86400
            
            # NFS/storage tuning for VM images
            extra_settings["sunrpc.tcp_slot_table_entries"]=$(( RAM / 4 < 64 ? 64 : (RAM / 4 > 256 ? 256 : RAM / 4) ))
            extra_settings["sunrpc.udp_slot_table_entries"]=$(( RAM / 4 < 64 ? 64 : (RAM / 4 > 256 ? 256 : RAM / 4) ))
            
            # KVM/QEMU specifics
            extra_settings["kernel.tsc_reliable"]=1
            extra_settings["kernel.randomize_va_space"]=0
            
            # 根据内存扩展文件描述符限制
            extra_settings["fs.file-max"]=$(( RAM * 2097152 < 1073741824 ? RAM * 2097152 : 1073741824 ))
            extra_settings["fs.inotify.max_user_watches"]=$(( RAM * 65536 < 8388608 ? RAM * 65536 : 8388608 ))
            extra_settings["fs.inotify.max_user_instances"]=$(( RAM * 32 < 8192 ? RAM * 32 : 8192 ))
            ;;
            
        "web")
            # 针对 Web 服务器优化的网络缓冲区设置
            extra_settings["net.core.rmem_max"]=$(( NIC >= 10000 ? 33554432 : 16777216 ))
            extra_settings["net.core.wmem_max"]=$(( NIC >= 10000 ? 33554432 : 16777216 ))
            extra_settings["net.core.rmem_default"]=1048576
            extra_settings["net.core.wmem_default"]=1048576
            extra_settings["net.core.optmem_max"]=4194304
            
            # Fix TCP rmem and wmem settings using if/then/else
            if [ "$NIC" -ge 10000 ]; then
                extra_settings["net.ipv4.tcp_rmem"]="4096 131072 33554432"
                extra_settings["net.ipv4.tcp_wmem"]="4096 131072 33554432" 
            else
                extra_settings["net.ipv4.tcp_rmem"]="4096 65536 16777216"
                extra_settings["net.ipv4.tcp_wmem"]="4096 65536 16777216"
            fi
            
            extra_settings["net.ipv4.udp_mem"]="4194304 8388608 16777216"
            extra_settings["net.ipv4.tcp_mem"]="786432 1048576 26777216"
            
            # Web 服务的内存调优
            extra_settings["vm.swappiness"]=$(( DISK_TYPE == "ssd" || DISK_TYPE == "nvme" ? 10 : 30 ))
            extra_settings["vm.vfs_cache_pressure"]=70
            extra_settings["vm.min_free_kbytes"]=$(( min_free_kb * 3/2 < RAM * 1024 ? RAM * 1024 : min_free_kb * 3/2 ))
            
            # SSD/NVMe 的低脏页比率
            if [[ "$DISK_TYPE" == "ssd" || "$DISK_TYPE" == "nvme" ]]; then
                extra_settings["vm.dirty_ratio"]=$(( RAM >= 32 ? 5 : 10 ))
                extra_settings["vm.dirty_background_ratio"]=$(( RAM >= 32 ? 2 : 5 ))
                extra_settings["vm.dirty_expire_centisecs"]=300
                extra_settings["vm.dirty_writeback_centisecs"]=100
            else
                extra_settings["vm.dirty_ratio"]=$(( RAM >= 32 ? 3 : 5 ))
                extra_settings["vm.dirty_background_ratio"]=$(( RAM >= 32 ? 1 : 2 ))
                extra_settings["vm.dirty_expire_centisecs"]=500
                extra_settings["vm.dirty_writeback_centisecs"]=250
            fi
            
            # 针对大量连接的网络调优
            extra_settings["net.core.somaxconn"]=$(( THREADS * 1024 < 4096 ? 4096 : (THREADS * 1024 > 262144 ? 262144 : THREADS * 1024) ))
            extra_settings["net.core.netdev_max_backlog"]=$(( NIC >= 10000 ? 250000 : (30000 > 65536 ? 30000 : 65536) ))
            extra_settings["net.ipv4.tcp_max_syn_backlog"]=$(( THREADS * 1024 > 8192 ? THREADS * 1024 : 8192 ))
            extra_settings["net.ipv4.tcp_fin_timeout"]=$(( NIC >= 10000 ? 10 : 15 ))
            extra_settings["net.ipv4.tcp_keepalive_time"]=600
            extra_settings["net.ipv4.tcp_max_tw_buckets"]=$(( RAM * 50000 < 6000000 ? RAM * 50000 : 6000000 ))
            extra_settings["net.ipv4.tcp_tw_reuse"]=1
            extra_settings["net.ipv4.tcp_fastopen"]=3
            extra_settings["net.ipv4.tcp_slow_start_after_idle"]=0
            
            # 根据内存扩展文件描述符限制
            extra_settings["fs.file-max"]=$(( RAM * 1048576 < 104857600 ? RAM * 1048576 : 104857600 ))
            extra_settings["fs.inotify.max_user_watches"]=$(( RAM * 131072 < 8388608 ? RAM * 131072 : 8388608 ))
            
            # 基于 CPU 数量的内核设置
            extra_settings["kernel.sched_min_granularity_ns"]=$(( CORES >= 16 ? 15000000 : 10000000 ))
            extra_settings["kernel.sched_wakeup_granularity_ns"]=$(( CORES >= 16 ? 20000000 : 15000000 ))
            extra_settings["kernel.pid_max"]=$(( RAM * 8192 < 1048576 ? 1048576 : (RAM * 8192 > 4194304 ? 4194304 : RAM * 8192) ))
            ;;
            
        "database")
            # 网络缓冲区设置
            extra_settings["net.core.rmem_max"]=$(( NIC >= 10000 ? 67108864 : 33554432 ))
            extra_settings["net.core.wmem_max"]=$(( NIC >= 10000 ? 67108864 : 33554432 ))
            extra_settings["net.core.rmem_default"]=4194304
            extra_settings["net.core.wmem_default"]=4194304
            extra_settings["net.core.optmem_max"]=8388608
            
            # Fix TCP rmem and wmem settings using if/then/else
            if [ "$NIC" -ge 10000 ]; then
                extra_settings["net.ipv4.tcp_rmem"]="8192 262144 67108864"
                extra_settings["net.ipv4.tcp_wmem"]="8192 262144 67108864"
            else
                extra_settings["net.ipv4.tcp_rmem"]="4096 131072 33554432"
                extra_settings["net.ipv4.tcp_wmem"]="4096 131072 33554432"
            fi
            
            extra_settings["net.ipv4.udp_mem"]="8388608 16777216 33554432"
            extra_settings["net.ipv4.tcp_mem"]="1048576 4194304 33554432"
            
            # 根据内存扩展的共享内存设置
            extra_settings["kernel.shmmax"]=$(( RAM * 1024 * 1024 * 1024 * (RAM >= 64 ? 80 : 90) / 100 ))
            extra_settings["kernel.shmall"]=$(( extra_settings["kernel.shmmax"] / 4096 ))
            extra_settings["kernel.shmmni"]=$(( RAM * 32 < 4096 ? 4096 : RAM * 32 ))
            
            # 内存管理
            extra_settings["vm.swappiness"]=$(( DISK_TYPE == "ssd" || DISK_TYPE == "nvme" ? 1 : 5 ))
            
            # 基于磁盘类型和内存的脏页比率
            if [[ "$DISK_TYPE" == "ssd" || "$DISK_TYPE" == "nvme" ]]; then
                extra_settings["vm.dirty_ratio"]=$(( RAM >= 32 ? 20 : 40 ))
                extra_settings["vm.dirty_background_ratio"]=$(( RAM >= 32 ? 5 : 10 ))
                extra_settings["vm.dirty_expire_centisecs"]=500
                extra_settings["vm.dirty_writeback_centisecs"]=100
            else
                extra_settings["vm.dirty_ratio"]=$(( RAM >= 32 ? 10 : 20 ))
                extra_settings["vm.dirty_background_ratio"]=$(( RAM >= 32 ? 3 : 5 ))
                extra_settings["vm.dirty_expire_centisecs"]=1000
                extra_settings["vm.dirty_writeback_centisecs"]=500
            fi
            
            extra_settings["vm.zone_reclaim_mode"]=0
            extra_settings["vm.min_free_kbytes"]=$(( min_free_kb * 2 < RAM * 2048 ? RAM * 2048 : min_free_kb * 2 ))
            
            # I/O settings based on disk type
            extra_settings["vm.vfs_cache_pressure"]=$(( DISK_TYPE == "ssd" || DISK_TYPE == "nvme" ? 50 : 125 ))
            extra_settings["vm.page-cluster"]=$(( DISK_TYPE == "ssd" || DISK_TYPE == "nvme" ? 0 : 3 ))
            
            # 数据库连接的网络设置
            extra_settings["net.core.somaxconn"]=$(( THREADS * 256 < 4096 ? 4096 : (THREADS * 256 > 65535 ? 65535 : THREADS * 256) ))
            extra_settings["net.ipv4.tcp_max_syn_backlog"]=$(( THREADS * 2048 < 131072 ? THREADS * 2048 : 131072 ))
            extra_settings["net.ipv4.tcp_keepalive_time"]=90
            extra_settings["net.ipv4.tcp_keepalive_intvl"]=10
            extra_settings["net.ipv4.tcp_keepalive_probes"]=9
            extra_settings["net.ipv4.tcp_max_tw_buckets"]=2000000
            extra_settings["net.ipv4.tcp_tw_reuse"]=0
            
            # 根据内存扩展文件描述符限制
            extra_settings["fs.aio-max-nr"]=$(( RAM * 65536 < 4194304 ? RAM * 65536 : 4194304 ))
            extra_settings["fs.file-max"]=$(( RAM * 2097152 < 104857600 ? RAM * 2097152 : 104857600 ))
            
            # 调度器调优
            extra_settings["kernel.sched_migration_cost_ns"]=$(( CORES >= 16 ? 5000000 : 1000000 ))
            extra_settings["kernel.sched_min_granularity_ns"]=10000
            extra_settings["kernel.sched_wakeup_granularity_ns"]=15000
            extra_settings["kernel.sched_autogroup_启用"]=0
            ;;
            
        "cache")
            # 网络缓冲区设置 - optimized for many small responses
            extra_settings["net.core.rmem_max"]=$(( NIC >= 10000 ? 33554432 : 16777216 ))
            extra_settings["net.core.wmem_max"]=$(( NIC >= 10000 ? 67108864 : 33554432 ))
            extra_settings["net.core.rmem_default"]=1048576
            extra_settings["net.core.wmem_default"]=4194304
            extra_settings["net.core.optmem_max"]=4194304
            
            # Fix TCP rmem and wmem settings using if/then/else
            if [ "$NIC" -ge 10000 ]; then
                extra_settings["net.ipv4.tcp_rmem"]="4096 65536 33554432"
                extra_settings["net.ipv4.tcp_wmem"]="4096 131072 67108864"
            else
                extra_settings["net.ipv4.tcp_rmem"]="4096 32768 16777216"
                extra_settings["net.ipv4.tcp_wmem"]="4096 65536 33554432"
            fi
            
            extra_settings["net.ipv4.udp_mem"]="8388608 16777216 33554432"
            extra_settings["net.ipv4.tcp_mem"]="1048576 4194304 33554432"
            
            # 缓存服务器的内存密集型设置
            extra_settings["vm.swappiness"]=0
            extra_settings["vm.overcommit_memory"]=1
            extra_settings["vm.overcommit_ratio"]=$(( 50 + RAM / 4 < 95 ? 50 + RAM / 4 : 95 ))
            extra_settings["vm.min_free_kbytes"]=$(( min_free_kb * 3/2 < RAM * 1024 ? RAM * 1024 : min_free_kb * 3/2 ))
            extra_settings["vm.vfs_cache_pressure"]=$(( 50 - RAM / 8 < 5 ? 5 : 50 - RAM / 8 ))
            extra_settings["vm.dirty_ratio"]=$(( RAM >= 64 ? 3 : 5 ))
            extra_settings["vm.dirty_background_ratio"]=$(( RAM >= 64 ? 1 : 2 ))
            extra_settings["vm.zone_reclaim_mode"]=0
            
            # 针对大量小请求的网络调优
            extra_settings["net.core.somaxconn"]=$(( THREADS * 2048 < 65535 ? 65535 : (THREADS * 2048 > 524288 ? 524288 : THREADS * 2048) ))
            extra_settings["net.ipv4.tcp_max_syn_backlog"]=$(( THREADS * 4096 < 65536 ? 65536 : (THREADS * 4096 > 262144 ? 262144 : THREADS * 4096) ))
            extra_settings["net.ipv4.tcp_max_tw_buckets"]=6000000
            extra_settings["net.ipv4.tcp_tw_reuse"]=1
            extra_settings["net.ipv4.tcp_fin_timeout"]=$(( NIC >= 10000 ? 5 : 10 ))
            extra_settings["net.core.netdev_max_backlog"]=$(( NIC >= 10000 ? 250000 : (30000 > 100000 ? 30000 : 100000) ))
            
            # 降低延迟的 CPU 设置
            extra_settings["kernel.sched_min_granularity_ns"]=$(( CORES <= 4 ? 5000 : 10000 ))
            extra_settings["kernel.sched_wakeup_granularity_ns"]=$(( CORES <= 4 ? 10000 : 15000 ))
            extra_settings["kernel.numa_balancing"]=0
            extra_settings["kernel.sched_migration_cost_ns"]=$(( CORES <= 8 ? 5000 : (CORES * 10000 > 100000 ? CORES * 10000 : 100000) ))
            extra_settings["kernel.sched_autogroup_启用"]=0
            
            # 根据内存扩展文件描述符限制
            extra_settings["fs.file-max"]=$(( RAM * 2097152 < 104857600 ? RAM * 2097152 : 104857600 ))
            extra_settings["fs.aio-max-nr"]=$(( RAM * 8192 < 1048576 ? RAM * 8192 : 1048576 ))
            ;;
            
        "compute")
            # 网络缓冲区设置
            extra_settings["net.core.rmem_max"]=$(( NIC >= 10000 ? 33554432 : 16777216 ))
            extra_settings["net.core.wmem_max"]=$(( NIC >= 10000 ? 33554432 : 16777216 ))
            extra_settings["net.core.rmem_default"]=2097152
            extra_settings["net.core.wmem_default"]=2097152
            extra_settings["net.core.optmem_max"]=4194304
            
            # Fix TCP rmem and wmem settings using if/then/else
            if [ "$NIC" -ge 10000 ]; then
                extra_settings["net.ipv4.tcp_rmem"]="4096 131072 33554432"
                extra_settings["net.ipv4.tcp_wmem"]="4096 131072 33554432"
            else
                extra_settings["net.ipv4.tcp_rmem"]="4096 65536 16777216"
                extra_settings["net.ipv4.tcp_wmem"]="4096 65536 16777216"
            fi
            
            extra_settings["net.ipv4.udp_mem"]="4194304 8388608 16777216"
            extra_settings["net.ipv4.tcp_mem"]="1048576 4194304 16777216"
            
            # 根据核心数调优的 CPU 调度器
            extra_settings["kernel.sched_min_granularity_ns"]=$(( CORES <= 4 ? 3000 : 5000 ))
            extra_settings["kernel.sched_wakeup_granularity_ns"]=$(( CORES <= 4 ? 5000 : 10000 ))
            extra_settings["kernel.sched_latency_ns"]=$(( CORES * 1000 < 10000 ? 10000 : (CORES * 1000 > 60000 ? 60000 : CORES * 1000) ))
            extra_settings["kernel.sched_migration_cost_ns"]=$(( CORES * 5000 < 50000 ? 50000 : CORES * 5000 ))
            extra_settings["kernel.sched_autogroup_启用"]=0
            extra_settings["kernel.numa_balancing"]=$(( CORES >= 32 ? 1 : 0 ))
            extra_settings["kernel.sched_rt_runtime_us"]=990000
            
            # 内存设置
            extra_settings["vm.swappiness"]=$(( DISK_TYPE == "ssd" || DISK_TYPE == "nvme" ? 1 : 5 ))
            extra_settings["vm.overcommit_ratio"]=$(( 50 + RAM / 16 < 95 ? 50 + RAM / 16 : 95 ))
            extra_settings["vm.min_free_kbytes"]=$(( min_free_kb * 6/5 < RAM * 512 ? RAM * 512 : min_free_kb * 6/5 ))
            extra_settings["vm.zone_reclaim_mode"]=$(( RAM >= 64 && CORES >= 16 ? 1 : 0 ))
            extra_settings["vm.transparent_hugepage.启用"]=$(( RAM >= 16 ? "always" : "madvise" ))
            extra_settings["vm.transparent_hugepage.defrag"]=$(( RAM >= 32 ? "always" : "madvise" ))
            
            # 根据内存和核心扩展的进程限制
            extra_settings["kernel.pid_max"]=$(( RAM * 32768 < 4194304 ? 4194304 : (RAM * 32768 > 4194304 * 4 ? 4194304 * 4 : RAM * 32768) ))
            extra_settings["kernel.线程-max"]=$(( RAM * 32768 < 4194304 ? 4194304 : (RAM * 32768 > 4194304 * 4 ? 4194304 * 4 : RAM * 32768) ))
            
            # 根据网卡速度扩展的网络性能
            extra_settings["net.core.busy_poll"]=$(( NIC >= 10000 ? 50 : 25 ))
            extra_settings["net.core.busy_read"]=$(( NIC >= 10000 ? 50 : 25 ))
            extra_settings["net.core.netdev_budget"]=$(( CORES * 20 < 300 ? 300 : (CORES * 20 > 1000 ? 1000 : CORES * 20) ))
            extra_settings["net.core.somaxconn"]=$(( THREADS * 128 < 1024 ? 1024 : (THREADS * 128 > 65535 ? 65535 : THREADS * 128) ))
            
            # 文件描述符限制
            extra_settings["fs.file-max"]=$(( RAM * 1048576 < 52428800 ? RAM * 1048576 : 52428800 ))
            extra_settings["fs.aio-max-nr"]=$(( RAM * 4096 < 1048576 ? RAM * 4096 : 1048576 ))
            ;;
            
        "fileserver")
            # 大文件传输的网络设置
            extra_settings["net.core.rmem_max"]=$(( NIC >= 40000 ? 134217728 : (NIC >= 10000 ? 67108864 : 33554432) ))
            extra_settings["net.core.wmem_max"]=$(( NIC >= 40000 ? 134217728 : (NIC >= 10000 ? 67108864 : 33554432) ))
            extra_settings["net.core.rmem_default"]=8388608
            extra_settings["net.core.wmem_default"]=8388608
            extra_settings["net.core.optmem_max"]=16777216
            
            # Fix TCP rmem and wmem settings using if/then/else
            if [ "$NIC" -ge 25000 ]; then
                extra_settings["net.ipv4.tcp_rmem"]="8192 262144 134217728"
                extra_settings["net.ipv4.tcp_wmem"]="8192 262144 134217728"
            else
                extra_settings["net.ipv4.tcp_rmem"]="4096 131072 67108864"
                extra_settings["net.ipv4.tcp_wmem"]="4096 131072 67108864"
            fi
            
            extra_settings["net.ipv4.udp_mem"]="16777216 33554432 67108864"
            extra_settings["net.ipv4.tcp_mem"]="16777216 33554432 67108864"
            
            # TCP 优化
            extra_settings["net.ipv4.tcp_window_scaling"]=1
            extra_settings["net.ipv4.tcp_timestamps"]=1
            extra_settings["net.ipv4.tcp_sack"]=1
            extra_settings["net.ipv4.tcp_slow_start_after_idle"]=0
            extra_settings["net.ipv4.tcp_fin_timeout"]=20
            extra_settings["net.core.netdev_max_backlog"]=$(( NIC >= 10000 ? 250000 : 100000 ))
            extra_settings["net.core.somaxconn"]=$(( THREADS * 512 < 2048 ? 2048 : (THREADS * 512 > 65535 ? 65535 : THREADS * 512) ))
            
            # NFS/SMB server settings
            extra_settings["sunrpc.tcp_slot_table_entries"]=$(( RAM * 8 < 128 ? 128 : (RAM * 8 > 2048 ? 2048 : RAM * 8) ))
            extra_settings["sunrpc.udp_slot_table_entries"]=$(( RAM * 8 < 128 ? 128 : (RAM * 8 > 2048 ? 2048 : RAM * 8) ))
            extra_settings["fs.nfsd.max_connections"]=$(( RAM * 64 < 256 ? 256 : (RAM * 64 > 65536 ? 65536 : RAM * 64) ))
            
            # 文件描述符限制
            extra_settings["fs.file-max"]=$(( RAM * 4194304 < 1073741824 ? RAM * 4194304 : 1073741824 ))
            extra_settings["fs.inotify.max_user_watches"]=$(( RAM * 131072 < 8388608 ? RAM * 131072 : 8388608 ))
            extra_settings["fs.inotify.max_user_instances"]=$(( RAM * 256 < 65536 ? RAM * 256 : 65536 ))
            extra_settings["fs.aio-max-nr"]=$(( RAM * 32768 < 4194304 ? RAM * 32768 : 4194304 ))
            
            # 用于缓存的内存
            if [[ "$DISK_TYPE" == "ssd" || "$DISK_TYPE" == "nvme" ]]; then
                extra_settings["vm.dirty_ratio"]=$(( RAM >= 32 ? 15 : 30 ))
                extra_settings["vm.dirty_background_ratio"]=$(( RAM >= 32 ? 3 : 5 ))
                extra_settings["vm.vfs_cache_pressure"]=50
                extra_settings["vm.swappiness"]=10
                extra_settings["vm.dirty_expire_centisecs"]=1500
                extra_settings["vm.dirty_writeback_centisecs"]=250
            else
                extra_settings["vm.dirty_ratio"]=$(( RAM >= 32 ? 10 : 20 ))
                extra_settings["vm.dirty_background_ratio"]=$(( RAM >= 32 ? 2 : 3 ))
                extra_settings["vm.vfs_cache_pressure"]=10
                extra_settings["vm.swappiness"]=20
                extra_settings["vm.dirty_expire_centisecs"]=3000
                extra_settings["vm.dirty_writeback_centisecs"]=500
            fi
            
            extra_settings["vm.min_free_kbytes"]=$(( min_free_kb * 3/2 < RAM * 1024 ? RAM * 1024 : min_free_kb * 3/2 ))
            ;;
            
        "network")
            # 网络缓冲区设置 - maximum throughput and buffering
            extra_settings["net.core.rmem_max"]=$(( NIC >= 40000 ? 268435456 : (NIC >= 10000 ? 134217728 : 67108864) ))
            extra_settings["net.core.wmem_max"]=$(( NIC >= 40000 ? 268435456 : (NIC >= 10000 ? 134217728 : 67108864) ))
            extra_settings["net.core.rmem_default"]=16777216
            extra_settings["net.core.wmem_default"]=16777216
            extra_settings["net.core.optmem_max"]=$(( NIC >= 25000 ? 67108864 : 33554432 ))
            
            # Fix TCP rmem and wmem settings using if/then/else
            if [ "$NIC" -ge 40000 ]; then
                extra_settings["net.ipv4.tcp_rmem"]="16384 1048576 268435456"
                extra_settings["net.ipv4.tcp_wmem"]="16384 1048576 268435456"
            elif [ "$NIC" -ge 10000 ]; then
                extra_settings["net.ipv4.tcp_rmem"]="8192 524288 134217728"
                extra_settings["net.ipv4.tcp_wmem"]="8192 524288 134217728"
            else
                extra_settings["net.ipv4.tcp_rmem"]="4096 262144 67108864"
                extra_settings["net.ipv4.tcp_wmem"]="4096 262144 67108864"
            fi
            
            # Fix UDP mem/TCP mem settings using if/then/else
            if [ "$NIC" -ge 25000 ]; then
                extra_settings["net.ipv4.udp_mem"]="33554432 67108864 134217728"
                extra_settings["net.ipv4.tcp_mem"]="33554432 67108864 134217728"
            else
                extra_settings["net.ipv4.udp_mem"]="16777216 33554432 67108864"
                extra_settings["net.ipv4.tcp_mem"]="16777216 33554432 67108864"
            fi
            
            # 路由和转发
            extra_settings["net.ipv4.ip_forward"]=1
            extra_settings["net.ipv6.conf.all.forwarding"]=1
            extra_settings["net.ipv4.conf.all.route_localnet"]=1
            extra_settings["net.ipv4.conf.all.rp_filter"]=2
            extra_settings["net.ipv4.conf.default.rp_filter"]=2
            
            # 根据内存扩展连接跟踪 and NIC
            extra_settings["net.netfilter.nf_conntrack_max"]=$(( RAM * 65536 < 8388608 ? RAM * 65536 : 8388608 ))
            extra_settings["net.netfilter.nf_conntrack_tcp_timeout_established"]=432000
            extra_settings["net.netfilter.nf_conntrack_tcp_timeout_time_wait"]=30
            
            # 网络设备的 TCP 调优
            extra_settings["net.core.netdev_max_backlog"]=$(( NIC >= 40000 ? 1000000 : 250000 ))
            extra_settings["net.core.netdev_budget"]=$(( CORES * 25 < 300 ? 300 : (CORES * 25 > 1000 ? 1000 : CORES * 25) ))
            extra_settings["net.core.netdev_budget_usecs"]=$(( NIC <= 1000 ? 4000 : 8000 ))
            extra_settings["net.core.netdev_budget_usecs"]=$(( extra_settings["net.core.netdev_budget_usecs"] < 2000 ? 2000 : (extra_settings["net.core.netdev_budget_usecs"] > 16000 ? 16000 : extra_settings["net.core.netdev_budget_usecs"]) ))
            extra_settings["net.core.dev_weight"]=600
            
            # Packet processing scaled to 线程 and NIC
            extra_settings["net.core.somaxconn"]=$(( THREADS * 2048 < 65535 ? 65535 : (THREADS * 2048 > 1048576 ? 1048576 : THREADS * 2048) ))
            extra_settings["net.ipv4.tcp_max_syn_backlog"]=$(( THREADS * 2048 < 65536 ? 65536 : (THREADS * 2048 > 1048576 ? 1048576 : THREADS * 2048) ))
            extra_settings["net.ipv4.tcp_adv_win_scale"]=$(( NIC >= 10000 ? 1 : 2 ))
            extra_settings["net.ipv4.tcp_no_metrics_save"]=1
            extra_settings["net.ipv4.tcp_slow_start_after_idle"]=0
            extra_settings["net.ipv4.tcp_max_tw_buckets"]=$(( RAM * 20000 < 2000000 ? 2000000 : (RAM * 20000 > 6000000 ? 6000000 : RAM * 20000) ))
            
            # 内存设置
            extra_settings["vm.min_free_kbytes"]=$(( min_free_kb * 2 < RAM * 2048 ? RAM * 2048 : min_free_kb * 2 ))
            extra_settings["vm.swappiness"]=10
            extra_settings["vm.dirty_ratio"]=5
            extra_settings["vm.dirty_background_ratio"]=2
            
            # 文件描述符限制
            extra_settings["fs.file-max"]=$(( RAM * 1048576 < 104857600 ? RAM * 1048576 : 104857600 ))
            extra_settings["fs.nr_open"]=$(( RAM * 1048576 < 104857600 ? RAM * 1048576 : 104857600 ))
            ;;
            
        "容器")
            # 网络缓冲区设置
            extra_settings["net.core.rmem_max"]=$(( NIC >= 10000 ? 67108864 : 33554432 ))
            extra_settings["net.core.wmem_max"]=$(( NIC >= 10000 ? 67108864 : 33554432 ))
            extra_settings["net.core.rmem_default"]=4194304
            extra_settings["net.core.wmem_default"]=4194304
            extra_settings["net.core.optmem_max"]=8388608
            
            # Fix TCP rmem and wmem settings using if/then/else
            if [ "$NIC" -ge 10000 ]; then
                extra_settings["net.ipv4.tcp_rmem"]="4096 262144 67108864"
                extra_settings["net.ipv4.tcp_wmem"]="4096 262144 67108864"
            else
                extra_settings["net.ipv4.tcp_rmem"]="4096 131072 33554432"
                extra_settings["net.ipv4.tcp_wmem"]="4096 131072 33554432"
            fi
            
            extra_settings["net.ipv4.udp_mem"]="8388608 16777216 33554432"
            extra_settings["net.ipv4.tcp_mem"]="4194304 8388608 33554432"
            
            # 内存管理
            extra_settings["vm.overcommit_memory"]=1
            extra_settings["vm.overcommit_ratio"]=$(( 50 + RAM / 4 < 95 ? 50 + RAM / 4 : 95 ))
            extra_settings["kernel.panic_on_oom"]=0
            extra_settings["vm.swappiness"]=$(( DISK_TYPE == "ssd" || DISK_TYPE == "nvme" ? 0 : 5 ))
            extra_settings["vm.vfs_cache_pressure"]=$(( DISK_TYPE == "ssd" || DISK_TYPE == "nvme" ? 50 : 75 ))
            extra_settings["vm.min_free_kbytes"]=$(( min_free_kb * 3/2 < RAM * 1024 ? RAM * 1024 : min_free_kb * 3/2 ))
            extra_settings["vm.dirty_ratio"]=10
            extra_settings["vm.dirty_background_ratio"]=5
            extra_settings["vm.dirty_expire_centisecs"]=500
            extra_settings["vm.dirty_writeback_centisecs"]=100
            
            # Namespace settings
            extra_settings["kernel.keys.root_maxkeys"]=$(( RAM * 4096 < 10000 ? 10000 : (RAM * 4096 > 2000000 ? 2000000 : RAM * 4096) ))
            extra_settings["kernel.keys.root_maxbytes"]=$(( RAM * 100000 < 1000000 ? 1000000 : (RAM * 100000 > 50000000 ? 50000000 : RAM * 100000) ))
            extra_settings["kernel.keys.maxkeys"]=$(( RAM * 16 < 1000 ? 1000 : (RAM * 16 > 4000 ? 4000 : RAM * 16) ))
            extra_settings["kernel.keys.maxbytes"]=$(( RAM * 16000 < 1000000 ? 1000000 : (RAM * 16000 > 4000000 ? 4000000 : RAM * 16000) ))
            extra_settings["user.max_user_namespaces"]=$(( RAM * 256 < 5000 ? 5000 : (RAM * 256 > 30000 ? 30000 : RAM * 256) ))
            extra_settings["user.max_ipc_namespaces"]=$(( RAM * 256 < 5000 ? 5000 : (RAM * 256 > 30000 ? 30000 : RAM * 256) ))
            extra_settings["user.max_pid_namespaces"]=$(( RAM * 256 < 5000 ? 5000 : (RAM * 256 > 30000 ? 30000 : RAM * 256) ))
            extra_settings["user.max_net_namespaces"]=$(( RAM * 256 < 5000 ? 5000 : (RAM * 256 > 30000 ? 30000 : RAM * 256) ))
            extra_settings["user.max_mnt_namespaces"]=$(( RAM * 256 < 5000 ? 5000 : (RAM * 256 > 30000 ? 30000 : RAM * 256) ))
            extra_settings["user.max_uts_namespaces"]=$(( RAM * 256 < 5000 ? 5000 : (RAM * 256 > 30000 ? 30000 : RAM * 256) ))
            
            # Process limits
            extra_settings["kernel.pid_max"]=$(( RAM * 32768 < 4194304 ? 4194304 : (RAM * 32768 > 4194304 * 4 ? 4194304 * 4 : RAM * 32768) ))
            extra_settings["kernel.线程-max"]=$(( RAM * 32768 < 4194304 ? 4194304 : (RAM * 32768 > 4194304 * 4 ? 4194304 * 4 : RAM * 32768) ))
            
            # Network for 容器s
            extra_settings["net.ipv4.ip_forward"]=1
            extra_settings["net.ipv6.conf.all.forwarding"]=1
            extra_settings["net.bridge.bridge-nf-call-ip6tables"]=1
            extra_settings["net.bridge.bridge-nf-call-iptables"]=1
            extra_settings["net.ipv4.conf.default.rp_filter"]=0
            extra_settings["net.ipv4.conf.all.rp_filter"]=0
            extra_settings["net.core.somaxconn"]=$(( THREADS * 1024 < 8192 ? 8192 : (THREADS * 1024 > 262144 ? 262144 : THREADS * 1024) ))
            extra_settings["net.ipv4.tcp_max_syn_backlog"]=$(( THREADS * 1024 < 8192 ? 8192 : (THREADS * 1024 > 262144 ? 262144 : THREADS * 1024) ))
            
            # 文件描述符限制
            extra_settings["fs.file-max"]=$(( RAM * 4194304 < 1073741824 ? RAM * 4194304 : 1073741824 ))
            extra_settings["fs.inotify.max_user_instances"]=$(( RAM * 512 < 65536 ? RAM * 512 : 65536 ))
            extra_settings["fs.inotify.max_user_watches"]=$(( RAM * 131072 < 16777216 ? RAM * 131072 : 16777216 ))
            extra_settings["fs.aio-max-nr"]=$(( RAM * 8192 < 1048576 ? RAM * 8192 : 1048576 ))
            ;;
            
        "development")
            # 网络缓冲区设置
            extra_settings["net.core.rmem_max"]=8388608
            extra_settings["net.core.wmem_max"]=8388608
            extra_settings["net.core.rmem_default"]=1048576
            extra_settings["net.core.wmem_default"]=1048576
            extra_settings["net.core.optmem_max"]=2097152
            extra_settings["net.ipv4.tcp_rmem"]="4096 65536 8388608"
            extra_settings["net.ipv4.tcp_wmem"]="4096 65536 8388608"
            extra_settings["net.ipv4.udp_mem"]="4194304 4194304 8388608"
            extra_settings["net.ipv4.tcp_mem"]="786432 1048576 4194304"
            
            # Desktop-friendly memory settings
            extra_settings["vm.swappiness"]=$(( DISK_TYPE == "ssd" || DISK_TYPE == "nvme" ? 10 : 20 ))
            extra_settings["vm.vfs_cache_pressure"]=$(( DISK_TYPE == "ssd" || DISK_TYPE == "nvme" ? 50 : 70 ))
            extra_settings["vm.dirty_ratio"]=$(( DISK_TYPE == "ssd" || DISK_TYPE == "nvme" ? 10 : 20 ))
            extra_settings["vm.dirty_background_ratio"]=$(( DISK_TYPE == "ssd" || DISK_TYPE == "nvme" ? 3 : 5 ))
            extra_settings["vm.dirty_expire_centisecs"]=$(( DISK_TYPE == "ssd" || DISK_TYPE == "nvme" ? 1500 : 3000 ))
            extra_settings["vm.dirty_writeback_centisecs"]=$(( DISK_TYPE == "ssd" || DISK_TYPE == "nvme" ? 250 : 500 ))
            extra_settings["vm.min_free_kbytes"]=$(( min_free_kb < RAM * 512 ? RAM * 512 : min_free_kb ))
            
            # Interactive scheduler settings
            extra_settings["kernel.sched_autogroup_启用"]=1
            extra_settings["kernel.sched_child_runs_first"]=1
            extra_settings["kernel.sched_min_granularity_ns"]=$(( CORES * 150000 < 1000000 ? 1000000 : (CORES * 150000 > 10000000 ? 10000000 : CORES * 150000) ))
            extra_settings["kernel.sched_wakeup_granularity_ns"]=$(( CORES * 200000 < 2000000 ? 2000000 : (CORES * 200000 > 15000000 ? 15000000 : CORES * 200000) ))
            extra_settings["kernel.sched_latency_ns"]=$(( CORES * 1000000 < 6000000 ? 6000000 : (CORES * 1000000 > 30000000 ? 30000000 : CORES * 1000000) ))
            extra_settings["kernel.sched_migration_cost_ns"]=$(( CORES * 30000 < 100000 ? 100000 : (CORES * 30000 > 2000000 ? 2000000 : CORES * 30000) ))
            
            # Moderate network settings
            extra_settings["net.core.somaxconn"]=$(( NIC >= 1000 ? 4096 : 1024 ))
            extra_settings["net.ipv4.tcp_fastopen"]=3
            extra_settings["net.ipv4.tcp_keepalive_time"]=600
            extra_settings["net.ipv4.tcp_max_syn_backlog"]=$(( NIC >= 1000 ? 2048 : 512 ))
            
            # 文件描述符限制 for IDEs
            extra_settings["fs.inotify.max_user_watches"]=$(( RAM * 65536 < 8388608 ? RAM * 65536 : 8388608 ))
            extra_settings["fs.file-max"]=$(( RAM * 32768 < 4194304 ? RAM * 32768 : 4194304 ))
            ;;
            
        "general")
            # 网络缓冲区设置
            extra_settings["net.core.rmem_max"]=$(( NIC >= 10000 ? 33554432 : 16777216 ))
            extra_settings["net.core.wmem_max"]=$(( NIC >= 10000 ? 33554432 : 16777216 ))
            extra_settings["net.core.rmem_default"]=2097152
            extra_settings["net.core.wmem_default"]=2097152
            extra_settings["net.core.optmem_max"]=4194304
            
            # Fix TCP rmem and wmem settings using if/then/else
            if [ "$NIC" -ge 10000 ]; then
                extra_settings["net.ipv4.tcp_rmem"]="4096 131072 33554432"
                extra_settings["net.ipv4.tcp_wmem"]="4096 131072 33554432"
            else
                extra_settings["net.ipv4.tcp_rmem"]="4096 65536 16777216"
                extra_settings["net.ipv4.tcp_wmem"]="4096 65536 16777216"
            fi
            
            extra_settings["net.ipv4.udp_mem"]="4194304 8388608 16777216"
            extra_settings["net.ipv4.tcp_mem"]="786432 1048576 16777216"
            
            # Network settings
            extra_settings["net.core.somaxconn"]=$(( THREADS * 256 < 4096 ? 4096 : (THREADS * 256 > 65535 ? 65535 : THREADS * 256) ))
            extra_settings["net.ipv4.tcp_max_syn_backlog"]=$(( THREADS * 512 < 8192 ? 8192 : (THREADS * 512 > 65536 ? 65536 : THREADS * 512) ))
            extra_settings["net.core.netdev_max_backlog"]=$(( NIC >= 10000 ? 250000 : 30000 ))
            
            # 内存设置
            extra_settings["vm.swappiness"]=$(( DISK_TYPE == "ssd" || DISK_TYPE == "nvme" ? 10 : 20 ))
            extra_settings["vm.vfs_cache_pressure"]=50
            extra_settings["vm.dirty_ratio"]=$(( RAM >= 32 ? 10 : 20 ))
            extra_settings["vm.dirty_background_ratio"]=$(( RAM >= 32 ? 3 : 5 ))
            extra_settings["vm.min_free_kbytes"]=$(( min_free_kb < RAM * 1024 ? RAM * 1024 : min_free_kb ))
            
            # Process limits
            extra_settings["kernel.pid_max"]=$(( RAM * 16384 < 4194304 ? RAM * 16384 : 4194304 ))
            extra_settings["fs.file-max"]=$(( RAM * 262144 < 26214400 ? RAM * 262144 : 26214400 ))
            
            # CPU scheduler settings
            extra_settings["kernel.sched_migration_cost_ns"]=$(( CORES <= 4 ? 100000 : 500000 ))
            extra_settings["kernel.sched_min_granularity_ns"]=10000
            extra_settings["kernel.sched_wakeup_granularity_ns"]=15000
            ;;
    esac

    # IPv6 settings based on user choice
    if $DISABLE_IPV6; then
        extra_settings["net.ipv6.conf.all.disable_ipv6"]=1
        extra_settings["net.ipv6.conf.default.disable_ipv6"]=1
        extra_settings["net.ipv6.conf.lo.disable_ipv6"]=1
    else
        # IPv6 tuned similarly to IPv4
        extra_settings["net.ipv6.conf.all.accept_redirects"]=0
        extra_settings["net.ipv6.conf.default.accept_redirects"]=0
        extra_settings["net.ipv6.conf.all.accept_ra"]=0
        extra_settings["net.ipv6.conf.default.accept_ra"]=0
        extra_settings["net.ipv6.neigh.default.gc_thresh1"]=1024
        extra_settings["net.ipv6.neigh.default.gc_thresh2"]=4096
        extra_settings["net.ipv6.neigh.default.gc_thresh3"]=8192
        extra_settings["net.ipv6.conf.all.disable_ipv6"]=0
        extra_settings["net.ipv6.conf.default.disable_ipv6"]=0
    fi

    # Merge extra_settings into all_settings
    for key in "${!extra_settings[@]}"; do
        for i in "${!all_settings[@]}"; do
            if [[ "${all_settings[$i]}" =~ ^"$key = " ]]; then
                all_settings[$i]="$key = ${extra_settings[$key]}"
                unset extra_settings[$key]
                break
            fi
        done
    done

    # Add any remaining extra_settings
    for key in "${!extra_settings[@]}"; do
        all_settings+=("$key = ${extra_settings[$key]}")
    done

    # Sort settings by key for better organization
    IFS=$'\n' all_settings=($(sort <<<"${all_settings[*]}"))
    unset IFS

    # Generate header for the config file
    local disk_type_name="HDD"
    [[ "$DISK_TYPE" == "ssd" ]] && disk_type_name="SSD" 
    [[ "$DISK_TYPE" == "nvme" ]] && disk_type_name="NVMe"
    
    local header="# 优化的 sysctl.conf 用于 ${USE_CASES[$USE_CASE]%%:*}
# 硬件： $CORES 核心 / $THREADS 线程, ${RAM}GB RAM, ${NIC}Mb/s NIC, $disk_type_name
# 生成于： $(date "+%Y-%m-%d %H:%M:%S")
#
# 应用更改： sudo sysctl -p $INSTALL_PATH
#
# 重要提示：使用您的特定工作负载测试这些设置。
#"

    # Combine header and settings
    echo "$header"
    printf "%s\n" "${all_settings[@]}"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    print_banner
    detect_容器
    detect_os
    echo -e "${BLUE}${BOLD}系统硬件检测：${NC}"
    detect_cpu
    detect_ram
    detect_nic_speed
    detect_disk_type
    
    confirm_or_input_hardware
    
    get_use_case
    ask_ipv6
    confirm_selection
    
    echo -e "\n${BLUE}${BOLD}正在生成优化的 sysctl.conf...${NC}"
    
    # Generate the configuration
    generate_sysctl_conf > "$OUTPUT_FILE"
    
    echo -e "\n${GREEN}${BOLD}优化完成！${NC}"
    echo -e "配置已保存到： ${CYAN}${OUTPUT_FILE}${NC}"
    echo
    echo -e "要应用这些设置："
    echo -e "  1. 查看配置： ${CYAN}less ${OUTPUT_FILE}${NC}"
    echo -e "  2. 将其复制到系统位置： ${CYAN}sudo cp ${OUTPUT_FILE} ${INSTALL_PATH}${NC}"
    echo -e "  3. 应用设置： ${CYAN}sudo sysctl -p ${INSTALL_PATH}${NC}"
    echo
    
    # Container-specific warnings
    if $IS_CONTAINER; then
        echo -e "${YELLOW}容器环境注意事项：${NC}"
        echo -e "- 某些设置可能需要主机权限，可能会被忽略"
        echo -e "- For LXC 容器s, you may need to adjust permissions (e.g., 'lxc.cap.drop=' in your 容器 config)"
        echo -e "- 考虑在主机系统上应用安全关键设置"
        echo
    fi
    
    echo -e "${YELLOW}Note: 在应用到生产环境之前，请务必在测试环境中测试这些设置。${NC}"
}

main
