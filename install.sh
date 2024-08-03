#!/bin/bash

# 参数
DomainName=$1
ServerIp=$2
AccessKeyId=$3
AccessKeySecret=$4
Postmaster=$5

if [ -z "$DomainName" ] || [ -z "$ServerIp" ] || [ -z "$AccessKeyId" ] || [ -z "$AccessKeySecret" ] || [ -z "$Postmaster" ]; then
  echo "Usage: $0 <DomainName> <ServerIp> <AccessKeyId> <AccessKeySecret> <Postmaster>"
  exit 1
fi
#环境检查 ubtuntu 20
if [ $(lsb_release -cs) != "focal" ]; then
  echo "This script is only supported on Ubuntu 20.04."
  exit 1
fi
#80端口检查
if lsof -i:80; then
  echo "Port 80 is already in use. Please stop the service and try again."
  exit 1
fi

# 创建文件夹
mkdir -p ~/docker-mailserver
cd ~/docker-mailserver
rm -rf ./*

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

# 删除所有容器
docker rm -f $(docker ps -a -q)

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

# 列出所有DNS记录并删除
# 获取所有记录的RecordId
RecordIds=$(aliyun alidns DescribeDomainRecords --DomainName $DomainName --output cols=RecordId rows=DomainRecords.Record[] | awk 'NR>2 {print $1}')

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
DMS_GITHUB_URL="https://raw.githubusercontent.com/kkazy001/DMS-install/main"
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
docker exec mailserver setup email add $Postmaster@${DomainName} 6c9W9LM65eGjM7tmHv
docker exec mailserver setup config dkim keysize 1024 domain $DomainName
sleep 5
#玄学
docker exec mailserver setup config dkim keysize 1024 domain $DomainName

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
echo mail.${DomainName},587,True,$Postmaster@${DomainName},6c9W9LM65eGjM7tmHv