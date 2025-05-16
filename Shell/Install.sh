#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

#=================================================
#	Description: 一键重装系统
#	Version: 1.0.1
#=================================================
github="raw.githubusercontent.com/Emokui/Nothing/Zero/Shell"
Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Yellow_font_prefix="\033[33m"
Blue_font_prefix="\033[34m"
Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Tip="${Yellow_font_prefix}[注意]${Font_color_suffix}"

# 检查系统
check_sys(){
    if [[ -f /etc/redhat-release ]]; then
        release="centos"
    elif cat /etc/issue | grep -q -E -i "debian"; then
        release="debian"
    elif cat /etc/issue | grep -q -E -i "ubuntu"; then
        release="ubuntu"
    elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
        release="centos"
    elif cat /proc/version | grep -q -E -i "debian"; then
        release="debian"
    elif cat /proc/version | grep -q -E -i "ubuntu"; then
        release="ubuntu"
    elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
        release="centos"
    fi
}

# 安装环境
first_job(){
    if [[ "${release}" == "centos" ]]; then
        yum install -y xz openssl gawk file
    elif [[ "${release}" == "debian" || "${release}" == "ubuntu" ]]; then
        apt-get update
        apt-get install -y xz-utils openssl gawk file
    fi
}

# 清理历史文件
clean_old_installnet(){
    [[ -f InstallNET.sh ]] && rm -f InstallNET.sh
}

# 安装系统
InstallOS(){
    read -p " 请设置密码:" pw
    if [[ "${model}" == "自动" ]]; then
        model="a"
    else
        model="m"
    fi
    if [[ "${country}" == "国外" ]]; then
        country=""
    else
        if [[ "${os}" == "u" ]]; then
            country="--mirror https://mirrors.tuna.tsinghua.edu.cn/ubuntu/"
        elif [[ "${os}" == "d" ]]; then
            country="--mirror https://mirrors.tuna.tsinghua.edu.cn/debian/"
        fi
    fi
    clean_old_installnet
    wget --no-check-certificate https://${github}/InstallNET.sh && chmod +x InstallNET.sh
    if [[ ! -f InstallNET.sh ]]; then
        echo -e "${Error} InstallNET.sh 下载失败，请检查网络连接或手动下载。"
        return 1
    fi
    bash InstallNET.sh -${os} ${1} -v ${vbit} -${model} -p ${pw} ${country}
}

# 切换位数
switchbit(){
    if [[ "${vbit}" == "64" ]]; then
        vbit="32"
    else
        vbit="64"
    fi
}

# 切换模式
switchmodel(){
    if [[ "${model}" == "自动" ]]; then
        model="手动"
    else
        model="自动"
    fi
}

# 切换国家
switchcountry(){
    if [[ "${country}" == "国外" ]]; then
        country="国内"
    else
        country="国外"
    fi
}

# 安装Debian
installDebian(){
    clear
    os="d"
    echo && echo -e "${Blue_font_prefix}一键网络重装管理脚本${Font_color_suffix} ${Red_font_prefix}[v${sh_ver}]${Font_color_suffix}
  
————————————选择版本————————————
 ${Green_font_prefix}1.${Font_color_suffix} 安装 Debian9系统
 ${Green_font_prefix}2.${Font_color_suffix} 安装 Debian10系统
 ${Green_font_prefix}3.${Font_color_suffix} 安装 Debian11系统
————————————切换模式————————————
 ${Green_font_prefix}4.${Font_color_suffix} 切换安装位数
 ${Green_font_prefix}5.${Font_color_suffix} 切换安装模式
 ${Green_font_prefix}6.${Font_color_suffix} 切换镜像源
————————————————————————————————
 ${Green_font_prefix}0.${Font_color_suffix} 返回主菜单" && echo

    echo -e " 当前模式: 安装${Yellow_font_prefix}${vbit}${Font_color_suffix}位系统，${Yellow_font_prefix}${model}${Font_color_suffix}模式,${Yellow_font_prefix}${country}${Font_color_suffix}镜像源。"
    echo
    read -p " 请输入数字 [0-6]:" num
    num=$(echo "$num" | grep -oE '^[0-9]+$')
    case "$num" in
        0)
            return
            ;;
        1)
            InstallOS "9"
            ;;
        2)
            InstallOS "10"
            ;;
        3)
            InstallOS "11"
            ;;
        4)
            switchbit
            ;;
        5)
            switchmodel
            ;;
        6)
            switchcountry
            ;;
        *)
            clear
            echo -e "${Error}:请输入正确数字 [0-6]"
            sleep 2s
            ;;
    esac
}

# 安装Ubuntu
installUbuntu(){
    clear
    os="u"
    echo && echo -e "${Blue_font_prefix}一键网络重装管理脚本${Font_color_suffix} ${Red_font_prefix}[v${sh_ver}]${Font_color_suffix}
  
————————————选择版本————————————
 ${Green_font_prefix}1.${Font_color_suffix} 安装 Ubuntu16系统
 ${Green_font_prefix}2.${Font_color_suffix} 安装 Ubuntu18系统
 ${Green_font_prefix}3.${Font_color_suffix} 安装 Ubuntu20系统
————————————切换模式————————————
 ${Green_font_prefix}4.${Font_color_suffix} 切换安装位数
 ${Green_font_prefix}5.${Font_color_suffix} 切换安装模式
 ${Green_font_prefix}6.${Font_color_suffix} 切换镜像源
————————————————————————————————
 ${Green_font_prefix}0.${Font_color_suffix} 返回主菜单" && echo

    echo -e " 当前模式: 安装${Yellow_font_prefix}${vbit}${Font_color_suffix}位系统，${Yellow_font_prefix}${model}${Font_color_suffix}模式,${Yellow_font_prefix}${country}${Font_color_suffix}镜像源。"
    echo
    read -p " 请输入数字 [0-6]:" num
    num=$(echo "$num" | grep -oE '^[0-9]+$')
    case "$num" in
        0)
            return
            ;;
        1)
            InstallOS "16.04"
            ;;
        2)
            InstallOS "18.04"
            ;;
        3)
            InstallOS "20.04"
            ;;
        4)
            switchbit
            ;;
        5)
            switchmodel
            ;;
        6)
            switchcountry
            ;;
        *)
            clear
            echo -e "${Error}:请输入正确数字 [0-6]"
            sleep 2s
            ;;
    esac
}

# 选项6功能
run_custom_reinstall() {
    echo -e "${Tip} 警告：此操作将DD重装为Debian 12，所有数据将丢失。确定继续？(y/N): "
    read confirm
    [[ $confirm == [yY] ]] || return
    bash <(curl -sL https://csnm.pages.dev/bin456789/reinstall/main/reinstall.sh) debian 12
}

# 主菜单
start_menu(){
    clear
    echo -e "${Blue_font_prefix}一键网络重装管理脚本${Font_color_suffix} ${Red_font_prefix}[v1.0.1]${Font_color_suffix}"
    echo
    echo -e "————————————重装系统————————————"
    echo -e " ${Green_font_prefix}1.${Font_color_suffix} 安装 Debian系统"
    echo -e " ${Green_font_prefix}2.${Font_color_suffix} 安装 Ubuntu系统"
    echo -e "————————————切换模式————————————"
    echo -e " ${Green_font_prefix}3.${Font_color_suffix} 切换安装位数"
    echo -e " ${Green_font_prefix}4.${Font_color_suffix} 切换安装模式"
    echo -e " ${Green_font_prefix}5.${Font_color_suffix} 切换镜像源"
    echo -e "————————————————————————————————"
    echo -e " ${Green_font_prefix}6.${Font_color_suffix} 重装为Debian12系统"
    echo -e " ${Green_font_prefix}0.${Font_color_suffix} 退出脚本"
    echo
    echo -e " 当前模式: 安装${Yellow_font_prefix}${vbit}${Font_color_suffix}位系统，${Yellow_font_prefix}${model}${Font_color_suffix}模式,${Yellow_font_prefix}${country}${Font_color_suffix}镜像源。"
    echo
}

main_loop() {
    while true; do
        start_menu
        read -p " 请输入数字 [0-6]:" num
        num=$(echo "$num" | grep -oE '^[0-9]+$')
        case "$num" in
            1) installDebian ;;
            2) installUbuntu ;;
            3) switchbit ;;
            4) switchmodel ;;
            5) switchcountry ;;
            6) run_custom_reinstall ;;
            0)
                echo -e "${Info} 脚本已退出。"
                break
                ;;
            *)
                clear
                echo -e "${Error}:请输入正确数字 [0-6]"
                sleep 2s
                ;;
        esac
    done
}

# 变量初始化与主流程
sh_ver="1.0.1"
check_sys
first_job
model="自动"
vbit="64"
country="国外"
main_loop
