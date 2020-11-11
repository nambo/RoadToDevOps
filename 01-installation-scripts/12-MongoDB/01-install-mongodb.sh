#!/bin/bash

#######################################
# 通用配置
user=root
passwd=654321
port=27017
bind_ip=0.0.0.0
#*******************yum部署配置，它与二进制配置之中，只有一个会生效
# 指定repo版本，生成配置需要，不能省略
repo_version=4.2
# yum安装，且需要指定特定小版本时填写，不需要指定时不用管
repo_version_mini=
# 数据存储目录，默认/var/lib/mongo，不需要改可以注释下面这行
dbpath=/data/mongodb
#*******************二进制部署配置
# 二进制部署包的版本
tgz_version=4.2.6
base_dir=/data/mongodb
######################################

# 所有需要下载的文件都下载到当前目录下的${src_dir}目录中
src_dir=00src00

releasever=$(awk -F '"' '/VERSION_ID/{print $2}' /etc/os-release)


function init_mongodb(){
    systemctl daemon-reload
    systemctl start mongod
    if [ $? -ne 0 ];then
        echo -e "\033[31m[*] mongodb启动出错，请检查！\033[0m"
        exit 2
    fi
    systemctl enable mongod &> /dev/null

    echo -e "\033[32m[>] 设置mongodb用户\033[0m"
    mongo admin --eval "db.createUser({user:\"${user}\", pwd:\"${passwd}\", roles:[{role:\"root\", db:\"admin\"}]})" &> /dev/null

    echo -e "\033[32m[>] 开启安全认证\033[0m"
    sed -i '/#security:/a security:\n  authorization: enabled' $1

    systemctl restart mongod
    if [ $? -ne 0 ];then
        echo -e "\033[31m[*] mongodb重启出错，请检查mongod.conf！\033[0m"
        exit 3
    fi

    echo -e "\033[36m[#] mongodb 已安装配置完成：\033[0m"
    echo -e "\033[36m    mongodb端口：${port}\033[0m"
    echo -e "\033[36m    超管账号：${user}\033[0m"
    echo -e "\033[36m    超管密码：${passwd}\033[0m"
}

function install_by_yum(){
    echo -e "\033[32m[+] 生成mongodb repo文件\033[0m"
cat > /etc/yum.repos.d/mongodb-org-${repo_version}.repo << EOF
[mongodb-org-${repo_version}]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/$releasever/mongodb-org/${repo_version}/x86_64/
enabled=1
gpgcheck=0
gpgkey=https://www.mongodb.org/static/pgp/server-${repo_version}.asc
EOF

    echo -e "\033[32m[>] yum安装mongodb\033[0m"
    if [ ! ${repo_version_mini} ];then
        yum install -y mongodb-org
    else
    # 指定小版本
        yum install -y mongodb-org-${repo_version_mini}
    fi

    if [ $? -ne 0 ];then
        echo -e "\033[31m[*] mongodb安装出错，请检查！\033[0m"
        exit 1
    fi

    [ -d ${dbpath} ] || mkdir -p ${dbpath}
    if [ -d ${dbpath} ];then
        echo -e "\033[31m[*] ${dbpath} 目录已存在，退出\033[0m"
        exit 10
    fi

    echo -e "\033[32m[>] 优化mongodb配置\033[0m"
    sed -i '/bindIp: 127.0.0.1/a  #  maxIncomingConnections: 65536  #进程允许的最大连接数 默认值为65536' /etc/mongod.conf 
cat > /tmp/mongo_install_temp_$(date +%F).sh << EOF
sed -i 's/port: 27017/port: ${port}/g' /etc/mongod.conf
sed -i 's/bindIp: 127.0.0.1/bindIp: ${bind_ip}/g' /etc/mongod.conf
sed -i 's#dbPath: /var/lib/mongo#dbPath: ${dbpath}#g' /etc/mongod.conf
sed -i 's#ExecStartPre=/usr/bin/mkdir -p /var/run/mongodb#ExecStartPre=/usr/bin/mkdir -p ${dbpath}#g' /usr/lib/systemd/system/mongod.service
sed -i 's#ExecStartPre=/usr/bin/chown mongod:mongod /var/run/mongodb#ExecStartPre=/usr/bin/chown mongod:mongod ${dbpath}#g' /usr/lib/systemd/system/mongod.service
sed -i 's#ExecStartPre=/usr/bin/chmod 0755 /var/run/mongodb#ExecStartPre=/usr/bin/chmod 0755 ${dbpath}#g' /usr/lib/systemd/system/mongod.service
EOF
    /bin/bash /tmp/mongo_install_temp_$(date +%F).sh
    rm -rf /tmp/mongo_install_temp_$(date +%F).sh

    init_mongodb /etc/mongod.conf
    echo -e "\033[36m    数据存储目录：${dbpath}\033[0m"
}


function add_user_and_group(){
    if id -g ${1} >/dev/null 2>&1; then
        echo -e "\033[32m[#] ${1}组已存在，无需创建\033[0m"
    else
        groupadd ${1}
        echo -e "\033[32m[+] 创建${1}组\033[0m"
    fi
    if id -u ${1} >/dev/null 2>&1; then
        echo -e "\033[32m[#] ${1}用户已存在，无需创建\033[0m"
    else
        useradd -M -g ${1} -s /sbin/nologin ${1}
        echo -e "\033[32m[+] 创建${1}用户\033[0m"
    fi
}

# 首先判断当前目录是否有压缩包：
#   I. 如果有压缩包，那么就在当前目录解压；
#   II.如果没有压缩包，那么就检查有没有 ${openssh_source_dir} 表示的目录;
#       1) 如果有目录，那么检查有没有压缩包
#           ① 有压缩包就解压
#           ② 没有压缩包则下载压缩包
#       2) 如果没有,那么就创建这个目录，然后 cd 到目录中，然后下载压缩包，然
#       后解压
# 解压的步骤都在后面，故此处只做下载

# 语法： download_tar_gz 文件名 保存的目录 下载链接
# 使用示例： download_tar_gz openssl-1.1.1h.tar.gz /data/openssh-update https://mirrors.cloud.tencent.com/openssl/source/openssl-1.1.1h.tar.gz
function download_tar_gz(){
    back_dir=$(pwd)
    file_in_the_dir=''  # 这个目录是后面编译目录的父目录

    ls $1 &> /dev/null
    if [ $? -ne 0 ];then
        # 进入此处表示脚本所在目录没有压缩包
        ls -d $2 &> /dev/null
        if [ $? -ne 0 ];then
            # 进入此处表示没有${openssh_source_dir}目录
            mkdir -p $2 && cd $2
            echo -e "\033[32m[+] 下载源码包 $1 至 $(pwd)/\033[0m"
            wget $3
            file_in_the_dir=$(pwd)
            # 返回脚本所在目录，这样这个函数才可以多次使用
            cd ${back_dir}
        else
            # 进入此处表示有${openssh_source_dir}目录
            cd $2
            ls $1 &> /dev/null
            if [ $? -ne 0 ];then
            # 进入此处表示${openssh_source_dir}目录内没有压缩包
                echo -e "\033[32m[+] 下载源码包 $1 至 $(pwd)/\033[0m"
                wget $3
                file_in_the_dir=$(pwd)
                cd ${back_dir}
            else
                # 进入此处，表示${openssh_source_dir}目录内有压缩包
                echo -e "\033[32m[!] 发现压缩包$(pwd)/$1\033[0m"
                file_in_the_dir=$(pwd)
                cd ${back_dir}
            fi
        fi
    else
        # 进入此处表示脚本所在目录有压缩包
        echo -e "\033[32m[!] 发现压缩包$(pwd)/$1\033[0m"
        file_in_the_dir=$(pwd)
    fi
}

# 解压
function untar_tgz(){
    echo -e "\033[32m[+] 解压 $1 中\033[0m"
    tar xf $1
    if [ $? -ne 0 ];then
        echo -e "\033[31m[*] 解压出错，请检查!\033[0m"
        exit 2
    fi
}

function install_by_tgz(){
    add_user_and_group mongod
    download_tar_gz mongodb-linux-x86_64-rhel70-${tgz_version}.tgz ${src_dir} https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-rhel70-${tgz_version}.tgz
    cd ${file_in_the_dir}
    untar_tgz mongodb-linux-x86_64-rhel70-${tgz_version}.tgz

    [ -d $(dirname ${base_dir}) ] || mkdir -p $(dirname ${base_dir})
    if [ -d ${base_dir} ];then
        echo -e "\033[31m[*] ${base_dir} 目录已存在，退出\033[0m"
        exit 10
    fi
    mv mongodb-linux-x86_64-rhel70-4.2.6 ${base_dir}
    cd ${base_dir}
    mkdir conf data logs
    chown -R mongod:mongod ${base_dir}
    chmod -R 0755 ${base_dir}
    echo -e "\033[32m[+] 生成配置文件mongod.conf\033[0m"
cat > conf/mongod.conf <<EOF
# mongod.conf

# for documentation of all options, see:
#   http://docs.mongodb.org/manual/reference/configuration-options/

# where to write logging data.
systemLog:
  destination: file
  logAppend: true
  path: ${base_dir}/logs/mongod.log

# Where and how to store data.
storage:
  dbPath: ${base_dir}/data
  journal:
    enabled: true
#  engine:
#  wiredTiger:

# how the process runs
processManagement:
  fork: true  # fork and run in background
  pidFilePath: ${base_dir}/mongod.pid  # location of pidfile
  timeZoneInfo: /usr/share/zoneinfo

# network interfaces
net:
  port: ${port}
  bindIp: ${bind_ip}  # Enter 0.0.0.0,:: to bind to all IPv4 and IPv6 addresses or, alternatively, use the net.bindIpAll setting.
#  maxIncomingConnections: 65536  #进程允许的最大连接数 默认值为65536


#security:

#operationProfiling:

#replication:

#sharding:

## Enterprise-Only Options

#auditLog:

#snmp:
EOF
    # 上面新生成的文件的数组是root，所以需要修改
    chown -R mongod:mongod ${base_dir}

    echo -e "\033[32m[+] 生成mongodb unit file文件\033[0m"
cat >/usr/lib/systemd/system/mongod.service <<EOF
[Unit]
Description=MongoDB Database Server
Documentation=https://docs.mongodb.org/manual
After=network.target

[Service]
User=mongod
Group=mongod
Environment="OPTIONS=-f ${base_dir}/conf/mongod.conf"
EnvironmentFile=-/etc/sysconfig/mongod
ExecStart=${base_dir}/bin/mongod \$OPTIONS
PermissionsStartOnly=true
PIDFile=${base_dir}/mongod.pid
Type=forking
# file size
LimitFSIZE=infinity
# cpu time
LimitCPU=infinity
# virtual memory size
LimitAS=infinity
# open files
LimitNOFILE=64000
# processes/threads
LimitNPROC=64000
# locked memory
LimitMEMLOCK=infinity
# total threads (user+kernel)
TasksMax=infinity
TasksAccounting=false
# Recommended limits for for mongod as specified in
# http://docs.mongodb.org/manual/reference/ulimit/#recommended-settings

[Install]
WantedBy=multi-user.target
EOF

    echo "PATH=$PATH:${base_dir}/bin" > /etc/profile.d/mongod.sh
    source /etc/profile

    init_mongodb ${base_dir}/conf/mongod.conf
    echo -e "\033[36m    数据存储目录：${base_dir}/data\033[0m"

}


function install_main_func(){
    read -p "请输入数字选择部署方式（如需退出请输入q）：" software
    case $software in
        1)
            echo -e "\033[32m[!] 即将使用 \033[36myum\033[32m 部署mongodb\033[0m"
            # 等待两秒，给用户手动取消的时间
            sleep 2
            install_by_yum
            ;;
        2)
            echo -e "\033[32m[!] 即将使用 \033[36m二进制包\033[32m 部署mongodb\033[0m"
            sleep 2
            install_by_tgz
            echo -e "\033[32m由于bash特性限制，在本终端连接mongodb需要先手动执行  \033[36msource /etc/profile\033[0m  \033[32m加载环境变量\033[0m"
            echo -e "\033[33m或者\033[32m新开一个终端连接mongodb\n\033[0m"
            ;;
        q|Q)
            exit 0
            ;;
        *)
            install_main_func
            ;;
    esac
}

echo -e "\033[31m\n[?] 本脚本支持两种方式部署mongodb：\033[0m"
echo -e "\033[36m[1]\033[32m yum部署"
echo -e "\033[36m[2]\033[32m 二进制包部署"
# 终止终端字体颜色
echo -e "\033[0m"
install_main_func