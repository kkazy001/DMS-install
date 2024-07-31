#!/bin/bash

# 参数
DomainName=$1
ServerIp=$2
AccessKeyId=$3
AccessKeySecret=$4
Postmaster=$5

# 安装Docker
sudo apt-get update
sudo apt-get install ca-certificates curl -y
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y

# 配置阿里云 CLI
curl -O -fsSL https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-amd64.tgz
tar zxf aliyun-cli-linux-latest-amd64.tgz
mv ./aliyun /usr/local/bin/

aliyun configure set \
        --profile profile \
        --mode AK \
        --region ap-northeast-1 \
        --access-key-id $AccessKeyId \
        --access-key-secret $AccessKeySecret

#设置DNS 8.8.8.8 1.1.1.1 114.114.114.114
# 设置要使用的 DNS 服务器
DNS_SERVERS="8.8.8.8 1.1.1.1 114.114.114.114"

# 判断 netplan 是否存在
if command -v netplan > /dev/null; then
    # 查找 netplan 配置文件
    NETPLAN_FILE=$(ls /etc/netplan/*.yaml)

    # 备份原始 netplan 配置文件
    sudo cp $NETPLAN_FILE ${NETPLAN_FILE}.bak

    # 修改 netplan 配置文件
    sudo sed -i "/^ *nameservers:/{n;d}" $NETPLAN_FILE
    sudo sed -i "/^ *dhcp4: true/a\        nameservers:\n          addresses: [$DNS_SERVERS]" $NETPLAN_FILE

    # 应用 netplan 配置
    sudo netplan apply

    echo "DNS 设置已使用 netplan 修改为: $DNS_SERVERS"

# 判断 systemd-resolved 是否存在
elif command -v systemctl > /dev/null && systemctl is-active systemd-resolved > /dev/null; then
    # 修改 /etc/systemd/resolved.conf 文件
    sudo sed -i "/^DNS=/d" /etc/systemd/resolved.conf
    echo "DNS=$DNS_SERVERS" | sudo tee -a /etc/systemd/resolved.conf

    # 重启 systemd-resolved 服务
    sudo systemctl restart systemd-resolved

    echo "DNS 设置已使用 systemd-resolved 修改为: $DNS_SERVERS"
else
    echo "未检测到 netplan 或 systemd-resolved，请手动配置 DNS 设置。"
fi

# 列出所有DNS记录并删除

# 获取所有记录的RecordId
RecordIds=$(aliyun alidns DescribeDomainRecords --DomainName britmums.net --output cols=RecordId rows=DomainRecords.Record[] | awk 'NR>2 {print $1}')

# 遍历所有RecordId并删除记录
for RecordId in $RecordIds; do
  aliyun alidns DeleteDomainRecord --RecordId $RecordId
done

echo "所有DNS记录已成功从阿里云删除。"

# A记录
aliyun alidns AddDomainRecord \
  --DomainName $DomainName \
  --RR "mail" \
  --Type A \
  --Value "$ServerIp" \
  --TTL 600

# SPF 记录
aliyun alidns AddDomainRecord \
  --DomainName $DomainName \
  --RR "@" \
  --Type TXT \
  --Value "v=spf1 ip4:$ServerIp -all" \
  --TTL 600

# DMARC 记录
aliyun alidns AddDomainRecord \
  --DomainName $DomainName \
  --RR "_dmarc" \
  --Type TXT \
  --Value "v=DMARC1; p=quarantine; sp=r; pct=100; aspf=r; adkim=s" \
  --TTL 600

# MX 记录
aliyun alidns AddDomainRecord \
  --DomainName $DomainName \
  --RR "@" \
  --Type MX \
  --Value "mail.${DomainName}" \
  --Priority 10 \
  --TTL 600

#TLS
docker run --rm \
  -v "${PWD}/docker-data/certbot/certs/:/etc/letsencrypt/" \
  -v "${PWD}/docker-data/certbot/logs/:/var/log/letsencrypt/" \
  -p 80:80 \
  certbot/certbot certonly --standalone -d mail.${DomainName} --agree-tos --no-eff-email --register-unsafely-without-email 

# 安装DMS
DMS_GITHUB_URL="https://raw.githubusercontent.com/dkkazy001/DMS-install/main"
wget "${DMS_GITHUB_URL}/compose.yaml"
wget "${DMS_GITHUB_URL}/mailserver.env"
wget "${DMS_GITHUB_URL}/setup.sh"
chmod a+x ./setup.sh

# 替换配置信息
sed -i "s/example.com/$DomainName/g" compose.yaml
sed -i "s/ENABLE_RSPAMD=0/ENABLE_RSPAMD=1/g" mailserver.env
sed -i "s/ENABLE_OPENDKIM=1/ENABLE_OPENDKIM=0/g" mailserver.env

# 启动Docker Mail Server
docker compose up -d

# 添加邮箱账户和配置DKIM
./setup.sh email add $Postmaster@${DomainName} 6c9W9LM65eGjM7tmHv
./setup.sh config dkim keysize 1024 domain $DomainName

# 读取 DKIM DNS 记录
docker cp mailserver:/tmp/docker-mailserver/rspamd/dkim/rsa-1024-mail-${DomainName}.public.dns.txt ./
DkimRecord=$(cat rsa-1024-mail-${DomainName}.public.dns.txt)

# DKIM 记录
aliyun alidns AddDomainRecord \
  --DomainName $DomainName \
  --RR "mail._domainkey" \
  --Type TXT \
  --Value "$DkimRecord" \
  --TTL 600
echo "所有DNS记录已成功添加到阿里云。"
echo "完成！！！"