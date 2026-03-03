#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# ====== 颜色变量 ======
Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Yellow_font_prefix="\033[33m"
Blue_font_prefix="\033[34m"
Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Tip="${Yellow_font_prefix}[注意]${Font_color_suffix}"

# ====== 检查系统类型 ======
check_sys() {
    if [[ -f /etc/redhat-release ]]; then
        release="centos"
    elif grep -qi "debian" /etc/issue; then
        release="debian"
    elif grep -qi "ubuntu" /etc/issue; then
        release="ubuntu"
    elif grep -qiE "centos|red hat|redhat" /etc/issue; then
        release="centos"
    elif grep -qi "debian" /proc/version; then
        release="debian"
    elif grep -qi "ubuntu" /proc/version; then
        release="ubuntu"
    elif grep -qiE "centos|red hat|redhat" /proc/version; then
        release="centos"
    fi
}

# ====== 安装基础环境 ======
first_job() {
    if [[ "${release}" == "centos" ]]; then
        yum install -y xz openssl gawk file wget cpio gzip iproute util-linux
    elif [[ "${release}" == "debian" || "${release}" == "ubuntu" ]]; then
        apt-get update
        apt-get install -y xz-utils openssl gawk file wget cpio gzip iproute2 util-linux
    fi
}

# ====== InstallNET 使用说明 ======
show_installnet_usage() {
    echo -ne " Usage:\n\tbash $(basename $0)\t-d/--debian [\033[33m\033[04mdists-name\033[0m]\n\t\t\t\t-u/--ubuntu [\033[04mdists-name\033[0m]\n\t\t\t\t-c/--centos [\033[04mdists-name\033[0m]\n\t\t\t\t-v/--ver [32/i386|64/\033[33m\033[04mamd64\033[0m] [\033[33m\033[04mdists-verison\033[0m]\n\t\t\t\t--ip-addr/--ip-gate/--ip-mask\n\t\t\t\t-apt/-yum/--mirror\n\t\t\t\t-dd/--image [disabled]\n\t\t\t\t-p [linux password]\n\t\t\t\t-port [linux ssh port]\n"
}

# ====== InstallNET 工具函数 ======
dependence(){
  Full='0';
  for BIN_DEP in `echo "$1" |sed 's/,/\n/g'`
    do
      if [[ -n "$BIN_DEP" ]]; then
        Found='0';
        for BIN_PATH in `echo "$PATH" |sed 's/:/\n/g'`
          do
            ls $BIN_PATH/$BIN_DEP >/dev/null 2>&1;
            if [ $? == '0' ]; then
              Found='1';
              break;
            fi
          done
        if [ "$Found" == '1' ]; then
          echo -en "[\033[32mok\033[0m]\t";
        else
          Full='1';
          echo -en "[\033[31mNot Install\033[0m]";
        fi
        echo -en "\t$BIN_DEP\n";
      fi
    done
  if [ "$Full" == '1' ]; then
    echo -ne "\n\033[31mError! \033[0mPlease use '\033[33mapt-get\033[0m' or '\033[33myum\033[0m' install it.\n\n\n"
    exit 1;
  fi
}

selectMirror(){
  [ $# -ge 3 ] || exit 1
  local Relese=$(echo "$1" |sed -r 's/(.*)/\L\1/')
  local DIST=$(echo "$2" |sed 's/\ //g' |sed -r 's/(.*)/\L\1/')
  local VER=$(echo "$3" |sed 's/\ //g' |sed -r 's/(.*)/\L\1/')
  local New=$(echo "$4" |sed 's/\ //g')
  [ -n "$Relese" ] && [ -n "$DIST" ] && [ -n "$VER" ] || exit 1
  if [ "$Relese" == "debian" ] || [ "$Relese" == "ubuntu" ]; then
    [ "$DIST" == "focal" ] && legacy="legacy-" || legacy=""
    TEMP="SUB_MIRROR/dists/${DIST}/main/installer-${VER}/current/${legacy}images/netboot/${Relese}-installer/${VER}/initrd.gz"
  elif [ "$Relese" == "centos" ]; then
    TEMP="SUB_MIRROR/${DIST}/os/${VER}/isolinux/initrd.img"
  fi
  [ -n "$TEMP" ] || exit 1
  mirrorStatus=0
  declare -A MirrorBackup
  MirrorBackup=(["debian0"]="" ["debian1"]="http://deb.debian.org/debian" ["debian2"]="http://archive.debian.org/debian" ["ubuntu0"]="" ["ubuntu1"]="http://archive.ubuntu.com/ubuntu" ["ubuntu2"]="http://ports.ubuntu.com" ["centos0"]="" ["centos1"]="http://mirror.centos.org/centos" ["centos2"]="http://vault.centos.org")
  echo "$New" |grep -q '^http://\|^https://\|^ftp://' && MirrorBackup[${Relese}0]="$New"
  for mirror in $(echo "${!MirrorBackup[@]}" |sed 's/\ /\n/g' |sort -n |grep "^$Relese")
    do
      Current="${MirrorBackup[$mirror]}"
      [ -n "$Current" ] || continue
      MirrorURL=`echo "$TEMP" |sed "s#SUB_MIRROR#${Current}#g"`
      wget --no-check-certificate --spider --timeout=3 -o /dev/null "$MirrorURL"
      [ $? -eq 0 ] && mirrorStatus=1 && break
    done
  [ $mirrorStatus -eq 1 ] && echo "$Current" || exit 1
}

netmask() {
  n="${1:-32}"
  b=""
  m=""
  for((i=0;i<32;i++)){
    [ $i -lt $n ] && b="${b}1" || b="${b}0"
  }
  for((i=0;i<4;i++)){
    s=`echo "$b"|cut -c$[$[$i*8]+1]-$[$[$i+1]*8]`
    [ "$m" == "" ] && m="$((2#${s}))" || m="${m}.$((2#${s}))"
  }
  echo "$m"
}

getInterface(){
  interface=""
  Interfaces=`cat /proc/net/dev |grep ':' |cut -d':' -f1 |sed 's/\s//g' |grep -iv '^lo\|^sit\|^stf\|^gif\|^dummy\|^vmnet\|^vir\|^gre\|^ipip\|^ppp\|^bond\|^tun\|^tap\|^ip6gre\|^ip6tnl\|^teql\|^ocserv\|^vpn'`
  defaultRoute=`ip route show default |grep "^default"`
  for item in `echo "$Interfaces"`
    do
      [ -n "$item" ] || continue
      echo "$defaultRoute" |grep -q "$item"
      [ $? -eq 0 ] && interface="$item" && break
    done
  echo "$interface"
}

getDisk(){
  disks=`lsblk | sed 's/[[:space:]]*$//g' |grep "disk$" |cut -d' ' -f1 |grep -v "fd[0-9]*\|sr[0-9]*" |head -n1`
  [ -n "$disks" ] || echo ""
  echo "$disks" |grep -q "/dev"
  [ $? -eq 0 ] && echo "$disks" || echo "/dev/$disks"
}

diskType(){
  echo `udevadm info --query all "$1" 2>/dev/null |grep 'ID_PART_TABLE_TYPE' |cut -d'=' -f2`
}

getGrub(){
  Boot="${1:-/boot}"
  folder=`find "$Boot" -type d -name "grub*" 2>/dev/null |head -n1`
  [ -n "$folder" ] || return
  fileName=`ls -1 "$folder" 2>/dev/null |grep '^grub.conf$\|^grub.cfg$'`
  if [ -z "$fileName" ]; then
    ls -1 "$folder" 2>/dev/null |grep -q '^grubenv$'
    [ $? -eq 0 ] || return
    folder=`find "$Boot" -type f -name "grubenv" 2>/dev/null |xargs dirname |grep -v "^$folder" |head -n1`
    [ -n "$folder" ] || return
    fileName=`ls -1 "$folder" 2>/dev/null |grep '^grub.conf$\|^grub.cfg$'`
  fi
  [ -n "$fileName" ] || return
  [ "$fileName" == "grub.cfg" ] && ver="0" || ver="1"
  echo "${folder}:${fileName}:${ver}"
}

lowMem(){
  mem=`grep "^MemTotal:" /proc/meminfo 2>/dev/null |grep -o "[0-9]*"`
  [ -n "$mem" ] || return 0
  [ "$mem" -le "524288" ] && return 1 || return 0
}

validate_grub_config(){
  local grub_file="$1"
  if command -v grub-script-check >/dev/null 2>&1; then
    grub-script-check "$grub_file" >/tmp/grub-script-check.log 2>&1
    return $?
  elif command -v grub2-script-check >/dev/null 2>&1; then
    grub2-script-check "$grub_file" >/tmp/grub-script-check.log 2>&1
    return $?
  fi
  local open_count close_count
  open_count=$(grep -o '{' "$grub_file" 2>/dev/null | wc -l | tr -d ' ')
  close_count=$(grep -o '}' "$grub_file" 2>/dev/null | wc -l | tr -d ' ')
  if grep -q 'menuentry ' "$grub_file" && [[ "$open_count" == "$close_count" ]]; then
    echo "Warning: grub-script-check/grub2-script-check not found, fallback to basic GRUB sanity check."
    : >/tmp/grub-script-check.log
    return 0
  fi
  echo "Error! grub-script-check/grub2-script-check not found and fallback GRUB check failed."
  return 1
}

installnet_main() {
  local tmpVER='' tmpDIST='' tmpURL='' tmpWORD='' tmpMirror=''
  local ipAddr='' ipMask='' ipGate='' ipDNS='8.8.8.8'
  local IncDisk='default' interface='' interfaceSelect='' Relese=''
  local sshPORT='22' ddMode='0' setNet='0' setRDP='0' setIPv6='0'
  local autoNet='0'
  local isMirror='0' FindDists='0' loaderMode='0' IncFirmware='0'
  local SpikCheckDIST='0' setInterfaceName='0' UNKNOWHW='0' UNVER='6.4'
  local GRUBDIR='' GRUBFILE='' GRUBVER='' VER='' setCMD='' setConsole='' GRUB_BACKUP=''

  while [[ $# -ge 1 ]]; do
    case $1 in
      -v|--ver) shift; tmpVER="$1"; shift;;
      -d|--debian) shift; Relese='Debian'; tmpDIST="$1"; shift;;
      -u|--ubuntu) shift; Relese='Ubuntu'; tmpDIST="$1"; shift;;
      -c|--centos) shift; Relese='CentOS'; tmpDIST="$1"; shift;;
      -dd|--image) shift; ddMode='1'; tmpURL="$1"; shift;;
      -p|--password) shift; tmpWORD="$1"; shift;;
      -i|--interface) shift; interfaceSelect="$1"; shift;;
      --ip-addr) shift; ipAddr="$1"; shift;;
      --ip-mask) shift; ipMask="$1"; shift;;
      --ip-gate) shift; ipGate="$1"; shift;;
      --ip-dns) shift; ipDNS="$1"; shift;;
      --dev-net) shift; setInterfaceName='1';;
      --loader) shift; loaderMode='1';;
      -apt|-yum|--mirror) shift; isMirror='1'; tmpMirror="$1"; shift;;
      -rdp) shift; setRDP='1'; WinRemote="$1"; shift;;
      -cmd) shift; setCMD="$1"; shift;;
      -console) shift; setConsole="$1"; shift;;
      -firmware) shift; IncFirmware="1";;
      -port) shift; sshPORT="$1"; shift;;
      --noipv6) shift; setIPv6='1';;
      -a|--auto|-m|--manual|-ssl) shift;;
      *) if [[ "$1" != 'error' ]]; then echo -ne "\nInvaild option: '$1'\n\n"; fi
         show_installnet_usage; exit 1;;
    esac
  done

  [[ "$EUID" -ne '0' ]] && echo "Error:This script must be run as root!" && exit 1;
  [[ "$ddMode" == '1' ]] && echo "Error! This simplified script only supports Linux network reinstall. DD image mode is disabled." && exit 1;

  if [[ "$loaderMode" == "0" ]]; then
    Grub=`getGrub "/boot"`
    [ -z "$Grub" ] && echo -ne "Error! Not Found grub.\n" && exit 1;
    GRUBDIR=`echo "$Grub" |cut -d':' -f1`
    GRUBFILE=`echo "$Grub" |cut -d':' -f2`
    GRUBVER=`echo "$Grub" |cut -d':' -f3`
    [[ "$GRUBVER" != "0" ]] && echo -ne "Error! Only GRUB2 is supported in safe mode.\n" && exit 1;
  fi

  [ -n "$Relese" ] || Relese='Debian'
  local linux_relese=$(echo "$Relese" |sed 's/\ //g' |sed -r 's/(.*)/\L\1/')
  clear && echo -e "\n\033[36m# Check Dependence\033[0m\n"

  [ -n "$ipAddr" ] && [ -n "$ipMask" ] && [ -n "$ipGate" ] && setNet='1';
  if [ "$setNet" == "0" ]; then
    dependence ip
    [ -n "$interface" ] || interface=`getInterface`
    [ -n "$interface" ] || { echo "Error! Network interface not found."; exit 1; }
    iAddr=`ip addr show dev $interface |grep "inet.*" |head -n1 |grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\/[0-9]\{1,2\}'`
    ipAddr=`echo ${iAddr} |cut -d'/' -f1`
    ipMask=`netmask $(echo ${iAddr} |cut -d'/' -f2)`
    ipGate=`ip route show default |grep "^default" |grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' |head -n1`
    [ -n "$ipAddr" ] && [ -n "$ipMask" ] && [ -n "$ipGate" ] && autoNet='1'
  fi
  if [ -z "$interface" ]; then
    dependence ip
    [ -n "$interface" ] || interface=`getInterface`
  fi
  local IPv4="$ipAddr"; local MASK="$ipMask"; local GATE="$ipGate";

  [ -n "$IPv4" ] && [ -n "$MASK" ] && [ -n "$GATE" ] && [ -n "$ipDNS" ] || {
    echo -ne '\nError: Invalid network config\n\n'
    show_installnet_usage; exit 1;
  }

  if [[ "$Relese" == 'Debian' ]] || [[ "$Relese" == 'Ubuntu' ]]; then
    dependence wget,awk,grep,sed,cut,cat,lsblk,cpio,gzip,find,dirname,basename;
  elif [[ "$Relese" == 'CentOS' ]]; then
    dependence wget,awk,grep,sed,cut,cat,lsblk,cpio,gzip,find,dirname,basename,file,xz;
  fi
  [ -n "$tmpWORD" ] && dependence openssl
  [ -n "$setCMD" ] && dependence base64
  local myPASSWORD
  [[ -n "$tmpWORD" ]] && myPASSWORD="$(openssl passwd -1 "$tmpWORD")";
  [[ -z "$myPASSWORD" ]] && myPASSWORD='$1$4BJZaD0A$y1QykUnJ6mXprENfwpseH0';

  tempDisk=`getDisk`; [ -n "$tempDisk" ] && IncDisk="$tempDisk"

  case `uname -m` in aarch64|arm64) VER="arm64";; x86|i386|i686) VER="i386";; x86_64|amd64) VER="amd64";; *) VER="";; esac
  tmpVER="$(echo "$tmpVER" |sed -r 's/(.*)/\L\1/')";
  if [[ "$VER" != "arm64" ]] && [[ -n "$tmpVER" ]]; then
    case "$tmpVER" in i386|i686|x86|32) VER="i386";; amd64|x86_64|x64|64) [[ "$Relese" == 'CentOS' ]] && VER='x86_64' || VER='amd64';; *) VER='';; esac
  fi

  if [[ ! -n "$VER" ]]; then
    echo "Error! Not Architecture."
    show_installnet_usage; exit 1;
  fi

  local DIST
  if [[ -z "$tmpDIST" ]]; then
    [ "$Relese" == 'Debian' ] && tmpDIST='buster';
    [ "$Relese" == 'Ubuntu' ] && tmpDIST='bionic';
    [ "$Relese" == 'CentOS' ] && tmpDIST='6.10';
  fi

  local LinuxMirror
  if [[ -n "$tmpDIST" ]]; then
    if [[ "$Relese" == 'Debian' ]]; then
      SpikCheckDIST='0'
      DIST="$(echo "$tmpDIST" |sed -r 's/(.*)/\L\1/')";
      echo "$DIST" |grep -q '[0-9]';
      [[ $? -eq '0' ]] && {
        isDigital="$(echo "$DIST" |grep -o '[\.0-9]\{1,\}' |sed -n '1h;1!H;$g;s/\n//g;$p' |cut -d'.' -f1)";
        [[ -n $isDigital ]] && {
          [[ "$isDigital" == '7' ]] && DIST='wheezy';
          [[ "$isDigital" == '8' ]] && DIST='jessie';
          [[ "$isDigital" == '9' ]] && DIST='stretch';
          [[ "$isDigital" == '10' ]] && DIST='buster';
          [[ "$isDigital" == '11' ]] && DIST='bullseye';
        }
      }
      LinuxMirror=$(selectMirror "$Relese" "$DIST" "$VER" "$tmpMirror")
    fi
    if [[ "$Relese" == 'Ubuntu' ]]; then
      SpikCheckDIST='0'
      DIST="$(echo "$tmpDIST" |sed -r 's/(.*)/\L\1/')";
      echo "$DIST" |grep -q '[0-9]';
      [[ $? -eq '0' ]] && {
        isDigital="$(echo "$DIST" |grep -o '[\.0-9]\{1,\}' |sed -n '1h;1!H;$g;s/\n//g;$p')";
        [[ -n $isDigital ]] && {
          [[ "$isDigital" == '12.04' ]] && DIST='precise';
          [[ "$isDigital" == '14.04' ]] && DIST='trusty';
          [[ "$isDigital" == '16.04' ]] && DIST='xenial';
          [[ "$isDigital" == '18.04' ]] && DIST='bionic';
          [[ "$isDigital" == '20.04' ]] && DIST='focal';
        }
      }
      LinuxMirror=$(selectMirror "$Relese" "$DIST" "$VER" "$tmpMirror")
    fi
    if [[ "$Relese" == 'CentOS' ]]; then
      SpikCheckDIST='1'
      DISTCheck="$(echo "$tmpDIST" |grep -o '[\.0-9]\{1,\}' |head -n1)";
      LinuxMirror=$(selectMirror "$Relese" "$DISTCheck" "$VER" "$tmpMirror")
      ListDIST="$(wget --no-check-certificate -qO- "$LinuxMirror/dir_sizes" |cut -f2 |grep '^[0-9]')"
      DIST="$(echo "$ListDIST" |grep "^$DISTCheck" |head -n1)"
      [[ -z "$DIST" ]] && {
        echo -ne '\nThe dists version not found in this mirror, Please check it! \n\n'
        show_installnet_usage; exit 1;
      }
      wget --no-check-certificate -qO- "$LinuxMirror/$DIST/os/$VER/.treeinfo" |grep -q 'general';
      [[ $? != '0' ]] && {
        echo -ne "\nThe version not found in this mirror, Please change mirror try again! \n\n";
        exit 1;
      }
    fi
  fi

  if [[ -z "$LinuxMirror" ]]; then
    echo -ne "\033[31mError! \033[0mInvaild mirror! \n"
    [ "$Relese" == 'Debian' ] && echo -en "\033[33mexample:\033[0m http://deb.debian.org/debian\n\n";
    [ "$Relese" == 'Ubuntu' ] && echo -en "\033[33mexample:\033[0m http://archive.ubuntu.com/ubuntu\n\n";
    [ "$Relese" == 'CentOS' ] && echo -en "\033[33mexample:\033[0m http://mirror.centos.org/centos\n\n";
    show_installnet_usage; exit 1;
  fi

  if [[ "$SpikCheckDIST" == '0' ]]; then
    DistsList="$(wget --no-check-certificate -qO- "$LinuxMirror/dists/" |grep -o 'href=.*/"' |cut -d'"' -f2 |sed '/-\|old\|Debian\|experimental\|stable\|test\|sid\|devel/d' |grep '^[^/]' |sed -n '1h;1!H;$g;s/\n//g;s/\//\;/g;$p')";
    for CheckDEB in `echo "$DistsList" |sed 's/;/\n/g'`
      do
        [[ "$CheckDEB" == "$DIST" ]] && FindDists='1' && break;
      done
    [[ "$FindDists" == '0' ]] && {
      echo -ne '\nThe dists version not found, Please check it! \n\n'
      show_installnet_usage; exit 1;
    }
  fi

  clear && echo -e "\n\033[36m# Install\033[0m\n"

  if [ -z "$interfaceSelect" ]; then
    if [[ "$linux_relese" == 'debian' ]] || [[ "$linux_relese" == 'ubuntu' ]]; then
      interfaceSelect="auto"
    elif [[ "$linux_relese" == 'centos' ]]; then
      interfaceSelect="link"
    fi
  fi

  if [[ "$linux_relese" == 'centos' ]]; then
    if [[ "$DIST" != "$UNVER" ]]; then
      awk 'BEGIN{print '${UNVER}'-'${DIST}'}' |grep -q '^-'
      if [ $? != '0' ]; then
        UNKNOWHW='1';
        echo -en "\033[33mThe version lower then \033[31m$UNVER\033[33m may not support in auto mode! \033[0m\n";
      fi
      awk 'BEGIN{print '${UNVER}'-'${DIST}'+0.59}' |grep -q '^-'
      if [ $? == '0' ]; then
        echo -en "\n\033[31mThe version higher then \033[33m6.10 \033[31mis not support in current! \033[0m\n\n"
        exit 1;
      fi
    fi
  fi

  echo -e "\n[\033[33m$Relese\033[0m] [\033[33m$DIST\033[0m] [\033[33m$VER\033[0m] Downloading..."

  local MirrorHost MirrorFolder
  if [[ "$linux_relese" == 'debian' ]] || [[ "$linux_relese" == 'ubuntu' ]]; then
    [ "$DIST" == "focal" ] && legacy="legacy-" || legacy=""
    wget --no-check-certificate -qO '/tmp/initrd.img' "${LinuxMirror}/dists/${DIST}/main/installer-${VER}/current/${legacy}images/netboot/${linux_relese}-installer/${VER}/initrd.gz"
    [[ $? -ne '0' ]] && echo -ne "\033[31mError! \033[0mDownload 'initrd.img' for \033[33m$linux_relese\033[0m failed! \n" && exit 1
    wget --no-check-certificate -qO '/tmp/vmlinuz' "${LinuxMirror}/dists/${DIST}/main/installer-${VER}/current/${legacy}images/netboot/${linux_relese}-installer/${VER}/linux"
    [[ $? -ne '0' ]] && echo -ne "\033[31mError! \033[0mDownload 'vmlinuz' for \033[33m$linux_relese\033[0m failed! \n" && exit 1
    MirrorHost="$(echo "$LinuxMirror" |awk -F'://|/' '{print $2}')";
    MirrorFolder="$(echo "$LinuxMirror" |awk -F''${MirrorHost}'' '{print $2}')";
    [ -n "$MirrorFolder" ] || MirrorFolder="/"
  elif [[ "$linux_relese" == 'centos' ]]; then
    wget --no-check-certificate -qO '/tmp/initrd.img' "${LinuxMirror}/${DIST}/os/${VER}/isolinux/initrd.img"
    [[ $? -ne '0' ]] && echo -ne "\033[31mError! \033[0mDownload 'initrd.img' for \033[33m$linux_relese\033[0m failed! \n" && exit 1
    wget --no-check-certificate -qO '/tmp/vmlinuz' "${LinuxMirror}/${DIST}/os/${VER}/isolinux/vmlinuz"
    [[ $? -ne '0' ]] && echo -ne "\033[31mError! \033[0mDownload 'vmlinuz' for \033[33m$linux_relese\033[0m failed! \n" && exit 1
  else
    show_installnet_usage; exit 1;
  fi
  if [[ "$linux_relese" == 'debian' ]]; then
    if [[ "$IncFirmware" == '1' ]]; then
      wget --no-check-certificate -qO '/tmp/firmware.cpio.gz' "http://cdimage.debian.org/cdimage/unofficial/non-free/firmware/${DIST}/current/firmware.cpio.gz"
      [[ $? -ne '0' ]] && echo -ne "\033[31mError! \033[0mDownload 'firmware' for \033[33m$linux_relese\033[0m failed! \n" && exit 1
    fi
  fi

  # ====== GRUB 处理 ======
  if [[ "$loaderMode" == "0" ]]; then
    [[ ! -f "${GRUBDIR}/${GRUBFILE}" ]] && echo "Error! Not Found ${GRUBFILE}. " && exit 1;
    GRUB_BACKUP="${GRUBDIR}/${GRUBFILE}.installnet.$(date +%Y%m%d%H%M%S).bak"
    cp -f "${GRUBDIR}/${GRUBFILE}" "$GRUB_BACKUP" || { echo "Error! Backup grub file failed."; exit 1; }
  else
    GRUBVER='-1'
  fi

  [[ "$GRUBVER" == '0' ]] && {
    READGRUB='/tmp/grub.read'
    awk '
    /^[[:space:]]*menuentry[[:space:]]/ {
      if (found) exit
      found = 1
      depth = 0
    }
    found {
      print
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        if (c == "}") depth--
      }
      if (depth == 0) exit
    }
    ' "$GRUBDIR/$GRUBFILE" > "$READGRUB"
    LoadNum="$(grep -c 'menuentry ' $READGRUB)"
    if [[ "$LoadNum" -eq '1' ]]; then
      sed '/^$/d' $READGRUB >/tmp/grub.new;
    elif [[ "$LoadNum" -gt '1' ]]; then
      CFG0="$(awk '/menuentry /{print NR}' $READGRUB|head -n 1)";
      CFG2="$(awk '/menuentry /{print NR}' $READGRUB|head -n 2 |tail -n 1)";
      CFG1="";
      for tmpCFG in `awk '/}/{print NR}' $READGRUB`
        do
          [ "$tmpCFG" -gt "$CFG0" -a "$tmpCFG" -lt "$CFG2" ] && CFG1="$tmpCFG";
        done
      [[ -z "$CFG1" ]] && { echo "Error! read $GRUBFILE. "; exit 1; }
      sed -n "$CFG0,$CFG1"p $READGRUB >/tmp/grub.new;
      [[ -f /tmp/grub.new ]] && [[ "$(grep -c '{' /tmp/grub.new)" -eq "$(grep -c '}' /tmp/grub.new)" ]] || {
        echo -ne "\033[31mError! \033[0mNot configure $GRUBFILE. \n"; exit 1;
      }
    fi
    [ ! -f /tmp/grub.new ] && echo "Error! $GRUBFILE. " && exit 1;
    sed -i "/menuentry.*/c\menuentry\ \'Install OS \[$DIST\ $VER\]\'\ --class debian\ --class\ gnu-linux\ --class\ gnu\ --class\ os\ \{" /tmp/grub.new
    sed -i "/echo.*Loading/d" /tmp/grub.new;
    INSERTGRUB="$(awk '/menuentry /{print NR}' $GRUBDIR/$GRUBFILE|head -n 1)"
    [[ -z "$INSERTGRUB" || "$INSERTGRUB" -le 0 ]] && echo "Error! read grub insert position failed." && exit 1;
  }

  if [[ "$loaderMode" == "0" ]]; then
    [[ -n "$(grep -E 'linux(efi|16)?[[:space:]].*/|kernel.*/' /tmp/grub.new |awk '{print $2}' |tail -n 1 |grep '^/boot/')" ]] && Type='InBoot' || Type='NoBoot';
    LinuxKernel="$(grep -E 'linux(efi|16)?[[:space:]].*/|kernel.*/' /tmp/grub.new |awk '{print $1}' |head -n 1)";
    [[ -z "$LinuxKernel" ]] && echo "Error! read grub config! " && exit 1;
    LinuxIMG="$(grep 'initrd.*/' /tmp/grub.new |awk '{print $1}' |tail -n 1)";
    [ -z "$LinuxIMG" ] && sed -i "/$LinuxKernel.*\//a\\\tinitrd\ \/" /tmp/grub.new && LinuxIMG='initrd';
    [[ "$setInterfaceName" == "1" ]] && Add_OPTION="net.ifnames=0 biosdevname=0" || Add_OPTION=""
    [[ "$setIPv6" == "1" ]] && Add_OPTION="$Add_OPTION ipv6.disable=1"
    lowMem || Add_OPTION="$Add_OPTION lowmem=+0"
    if [[ "$linux_relese" == 'debian' ]] || [[ "$linux_relese" == 'ubuntu' ]]; then
      BOOT_OPTION="auto=true $Add_OPTION hostname=$linux_relese domain= quiet"
    elif [[ "$linux_relese" == 'centos' ]]; then
      BOOT_OPTION="ks=file://ks.cfg $Add_OPTION ksdevice=$interfaceSelect"
    fi
    [ -n "$setConsole" ] && BOOT_OPTION="$BOOT_OPTION --- console=$setConsole"
    [[ "$Type" == 'InBoot' ]] && {
      sed -i "/$LinuxKernel.*\//c\\\t$LinuxKernel\\t\/boot\/vmlinuz $BOOT_OPTION" /tmp/grub.new;
      sed -i "/$LinuxIMG.*\//c\\\t$LinuxIMG\\t\/boot\/initrd.img" /tmp/grub.new;
    }
    [[ "$Type" == 'NoBoot' ]] && {
      sed -i "/$LinuxKernel.*\//c\\\t$LinuxKernel\\t\/vmlinuz $BOOT_OPTION" /tmp/grub.new;
      sed -i "/$LinuxIMG.*\//c\\\t$LinuxIMG\\t\/initrd.img" /tmp/grub.new;
    }
    sed -i '$a\\n' /tmp/grub.new;
    GRUB_TMP="$(mktemp)"
    head -n $((INSERTGRUB-1)) "$GRUBDIR/$GRUBFILE" >"$GRUB_TMP"
    cat /tmp/grub.new >>"$GRUB_TMP"
    tail -n +"$INSERTGRUB" "$GRUBDIR/$GRUBFILE" >>"$GRUB_TMP"
    cp -f "$GRUB_TMP" "$GRUBDIR/$GRUBFILE"
    rm -f "$GRUB_TMP"

    if ! validate_grub_config "$GRUBDIR/$GRUBFILE"; then
      cp -f "$GRUB_BACKUP" "$GRUBDIR/$GRUBFILE"
      echo -ne "\033[31mError! \033[0mGRUB syntax check failed, rollback done. log: /tmp/grub-script-check.log\n"
      exit 1
    fi
    [[ -f  $GRUBDIR/grubenv ]] && sed -i 's/saved_entry/#saved_entry/g' $GRUBDIR/grubenv;
  fi

  [[ -d /tmp/boot ]] && rm -rf /tmp/boot;
  mkdir -p /tmp/boot;
  cd /tmp/boot;

  local COMPTYPE
  if [[ "$linux_relese" == 'debian' ]] || [[ "$linux_relese" == 'ubuntu' ]]; then
    COMPTYPE="gzip";
  elif [[ "$linux_relese" == 'centos' ]]; then
    COMPTYPE="$(file ../initrd.img |grep -o ':.*compressed data' |cut -d' ' -f2 |sed -r 's/(.*)/\L\1/' |head -n1)"
    [[ -z "$COMPTYPE" ]] && echo "Detect compressed type fail." && exit 1;
  fi
  CompDected='0'
  for COMP in `echo -en 'gzip\nlzma\nxz'`
    do
      if [[ "$COMPTYPE" == "$COMP" ]]; then
        CompDected='1'
        if [[ "$COMPTYPE" == 'gzip' ]]; then
          NewIMG="initrd.img.gz"
        else
          NewIMG="initrd.img.$COMPTYPE"
        fi
        mv -f "/tmp/initrd.img" "/tmp/$NewIMG"
        break;
      fi
    done
  [[ "$CompDected" != '1' ]] && echo "Detect compressed type not support." && exit 1;
  [[ "$COMPTYPE" == 'lzma' ]] && UNCOMP='xz --format=lzma --decompress';
  [[ "$COMPTYPE" == 'xz' ]] && UNCOMP='xz --decompress';
  [[ "$COMPTYPE" == 'gzip' ]] && UNCOMP='gzip -d';

  $UNCOMP < /tmp/$NewIMG | cpio --extract --verbose --make-directories --no-absolute-filenames >>/dev/null 2>&1

  # ====== Preseed / Kickstart 生成 ======
  if [[ "$linux_relese" == 'debian' ]] || [[ "$linux_relese" == 'ubuntu' ]]; then
  local partman_early_command='debconf-set partman-auto/disk "$(list-devices disk | head -n1)"'
  local late_command
  local cmd_b64=''
  late_command="sed -ri 's/^#?Port.*/Port ${sshPORT}/g' /target/etc/ssh/sshd_config; sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin yes/g' /target/etc/ssh/sshd_config; sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/g' /target/etc/ssh/sshd_config"
  if [[ -n "$setCMD" ]]; then
    cmd_b64="$(printf '%s' "$setCMD" | base64 | tr -d '\n')"
    late_command="${late_command}; printf '%s\n' '@reboot root base64 -d /etc/run.sh >/tmp/run.sh 2>/dev/null; rm -f /etc/run.sh; sed -i /^@reboot/d /etc/crontab; bash /tmp/run.sh' >>/target/etc/crontab; printf '\n' >>/target/etc/crontab; printf '%s' '${cmd_b64}' >/target/etc/run.sh"
  fi
cat >/tmp/boot/preseed.cfg<<EOF
d-i debian-installer/locale string en_US
d-i console-setup/layoutcode string us

d-i keyboard-configuration/xkb-keymap string us

d-i netcfg/choose_interface select $interfaceSelect

d-i netcfg/disable_autoconfig boolean true
d-i netcfg/dhcp_failed note
d-i netcfg/dhcp_options select Configure network manually
d-i netcfg/get_ipaddress string $IPv4
d-i netcfg/get_netmask string $MASK
d-i netcfg/get_gateway string $GATE
d-i netcfg/get_nameservers string $ipDNS
d-i netcfg/confirm_static boolean true

d-i hw-detect/load_firmware boolean true

d-i mirror/country string manual
d-i mirror/http/hostname string $MirrorHost
d-i mirror/http/directory string $MirrorFolder
d-i mirror/http/proxy string

d-i passwd/root-login boolean true
d-i passwd/make-user boolean false
d-i passwd/root-password-crypted password $myPASSWORD
d-i user-setup/allow-password-weak boolean true
d-i user-setup/encrypt-home boolean false

d-i clock-setup/utc boolean true
d-i time/zone string Etc/UTC
d-i clock-setup/ntp boolean false

d-i partman/early_command string $partman_early_command

d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/mount_style select uuid
d-i partman/choose_partition select finish
d-i partman-auto/method string regular
d-i partman-auto/init_automatically_partition select Guided - use entire disk
d-i partman-auto/choose_recipe select All files in one partition (recommended for new users)
d-i partman-md/device_remove_md boolean true
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

d-i debian-installer/allow_unauthenticated boolean true

tasksel tasksel/first multiselect standard
d-i pkgsel/update-policy select none
d-i pkgsel/include string openssh-server
d-i pkgsel/upgrade select none

popularity-contest popularity-contest/participate boolean false

d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i grub-installer/bootdev string $IncDisk
d-i grub-installer/force-efi-extra-removable boolean true
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/reboot boolean true
d-i preseed/late_command string $late_command
EOF

  if [[ "$loaderMode" != "0" ]] && [[ "$autoNet" == '1' ]]; then
    sed -i '/netcfg\/disable_autoconfig/d' /tmp/boot/preseed.cfg
    sed -i '/netcfg\/dhcp_failed/d' /tmp/boot/preseed.cfg
    sed -i '/netcfg\/dhcp_options/d' /tmp/boot/preseed.cfg
    sed -i '/netcfg\/get_.*/d' /tmp/boot/preseed.cfg
    sed -i '/netcfg\/confirm_static/d' /tmp/boot/preseed.cfg
  fi

  if [[ "$linux_relese" == 'debian' ]]; then
    sed -i '/user-setup\/allow-password-weak/d' /tmp/boot/preseed.cfg
    sed -i '/user-setup\/encrypt-home/d' /tmp/boot/preseed.cfg
    sed -i '/pkgsel\/update-policy/d' /tmp/boot/preseed.cfg
    [[ -f '/tmp/firmware.cpio.gz' ]] && gzip -d < /tmp/firmware.cpio.gz | cpio --extract --verbose --make-directories --no-absolute-filenames >>/dev/null 2>&1
  else
    sed -i '/d-i\ grub-installer\/force-efi-extra-removable/d' /tmp/boot/preseed.cfg
  fi

  elif [[ "$linux_relese" == 'centos' ]]; then
cat >/tmp/boot/ks.cfg<<EOF
#platform=x86, AMD64, or Intel EM64T
firewall --enabled --ssh
install
url --url="$LinuxMirror/$DIST/os/$VER/"
rootpw --iscrypted $myPASSWORD
auth --useshadow --passalgo=sha512
firstboot --disable
lang en_US
keyboard us
selinux --disabled
logging --level=info
reboot
text
unsupported_hardware
vnc
skipx
timezone --isUtc Asia/Hong_Kong
#ONDHCP network --bootproto=dhcp --onboot=on
network --bootproto=static --ip=$IPv4 --netmask=$MASK --gateway=$GATE --nameserver=$ipDNS --onboot=on
bootloader --location=mbr --append="rhgb quiet crashkernel=auto"
zerombr
clearpart --all --initlabel 
autopart

%packages
@base
%end

%post --interpreter=/bin/bash
rm -rf /root/anaconda-ks.cfg
rm -rf /root/install.*log
%end

EOF

  [[ "$UNKNOWHW" == '1' ]] && sed -i 's/^unsupported_hardware/#unsupported_hardware/g' /tmp/boot/ks.cfg
  [[ "$(echo "$DIST" |grep -o '^[0-9]\{1\}')" == '5' ]] && sed -i '0,/^%end/s//#%end/' /tmp/boot/ks.cfg
  fi

  # ====== 打包 initrd 并完成安装 ======
  find . | cpio -H newc --create --verbose | gzip -9 > /tmp/initrd.img;
  cp -f /tmp/initrd.img /boot/initrd.img || sudo cp -f /tmp/initrd.img /boot/initrd.img
  cp -f /tmp/vmlinuz /boot/vmlinuz || sudo cp -f /tmp/vmlinuz /boot/vmlinuz

  if [[ "$loaderMode" == "0" ]]; then
    chown root:root "$GRUBDIR/$GRUBFILE"
    chmod 444 "$GRUBDIR/$GRUBFILE"
  fi

  if [[ "$loaderMode" == "0" ]]; then
    read -r -p " GRUB 已校验通过。输入 REBOOT 立即重启继续安装，其它键取消自动重启: " confirm_reboot
    if [[ "$confirm_reboot" == "REBOOT" ]]; then
      sleep 3 && reboot || sudo reboot >/dev/null 2>&1
    else
      echo -e "${Tip} 已取消自动重启，请在确认无误后手动执行 reboot。"
    fi
  else
    rm -rf "$HOME/loader"
    mkdir -p "$HOME/loader"
    cp -rf "/boot/initrd.img" "$HOME/loader/initrd.img"
    cp -rf "/boot/vmlinuz" "$HOME/loader/vmlinuz"
    [[ -f "/boot/initrd.img" ]] && rm -rf "/boot/initrd.img"
    [[ -f "/boot/vmlinuz" ]] && rm -rf "/boot/vmlinuz"
    echo && ls -AR1 "$HOME/loader"
  fi
}

reinstall_debian11() {
    read -r -s -p " 请设置 root 密码: " pw
    echo
    if [[ -z "$pw" ]]; then
        echo -e "${Error} 密码不能为空。"
        return
    fi
    read -r -s -p " 请再次输入 root 密码: " pw2
    echo
    if [[ "$pw" != "$pw2" ]]; then
        echo -e "${Error} 两次输入密码不一致。"
        return
    fi

    echo -e "${Tip} 将使用 Debian 11 执行重装。"
    installnet_main -d 11 -v 64 -a -p "${pw}"
}

# ====== 主菜单输出 ======
start_menu() {
    clear
    echo -e "${Blue_font_prefix}一键网络重装管理脚本${Font_color_suffix} ${Red_font_prefix}[v2.0.0]${Font_color_suffix}"
    echo
    echo -e "————————————重装系统————————————"
    echo -e " ${Green_font_prefix}1.${Font_color_suffix} 重装 Debian 11"
    echo -e " ${Green_font_prefix}0.${Font_color_suffix} 退出脚本"
    echo
}

# ====== 主循环 ======
main_loop() {
    while true; do
        start_menu
        read -p " 请输入数字 [0-1]: " num
        num=$(echo "$num" | grep -oE '^[0-9]+$')
        case "$num" in
            1) reinstall_debian11 ;;
            0)
                echo -e "${Info} 脚本已退出。"
                break
                ;;
            *)
                clear
                echo -e "${Error}:请输入正确数字 [0-1]"
                sleep 2s
                ;;
        esac
    done
}

# ====== 主程序入口 ======
check_sys
[[ "$EUID" -ne '0' ]] && echo -e "${Error} 请使用 root 权限运行此脚本" && exit 1
[[ -z "${release}" ]] && echo -e "${Error} 暂不支持当前系统" && exit 1
first_job
main_loop
