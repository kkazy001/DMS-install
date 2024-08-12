#!/bin/bash

# 参数
DomainFilePath=$1
IPFilePath=$2
AccessKeyId=$3
AccessKeySecret=$4
Postmaster=$5

if [ -z "$DomainFilePath" ] || [ -z "$IPFilePath" ] || [ -z "$AccessKeyId" ] || [ -z "$AccessKeySecret" ] || [ -z "$Postmaster" ]; then
  echo "Usage: $0 <DomainFilePath> <IPFilePath> <AccessKeyId> <AccessKeySecret> <Postmaster>"
  exit 1
fi

# 读取域名数组
mapfile -t domains <"$DomainFilePath"

# 检查Ubuntu版本
if [ $(lsb_release -cs) != "focal" ]; then
  echo "This script is only supported on Ubuntu 20.04."
  exit 1
fi

# 80端口检查
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
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

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

# 清除已有的POSTROUTING规则，防止重复添加
iptables -t nat -F POSTROUTING
# 读取IP地址数组
mapfile -t ips <"$IPFilePath"

# 去除每个IP地址中的CR字符
for i in "${!ips[@]}"; do
  ips[$i]=$(echo "${ips[$i]}" | tr -d '\r')
done

for ip in "${ips[@]}"; do
  if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Invalid IP address format: $ip"
    exit 1
  fi
done

# 计算数组长度
num_ips=${#ips[@]}

# 添加SNAT规则
for i in ${!ips[@]}; do
  ip=${ips[$i]}
  # 使用--every num_ips 确保每 num_ips 个包使用一个不同的IP地址
  iptables -t nat -A POSTROUTING -o eno1 -p tcp -m state --state NEW -m tcp --dport 25 -m statistic --mode nth --every $num_ips --packet $i -j SNAT --to-source $ip
done

# 组装SPF记录
spf_record="v=spf1"
for ip in "${ips[@]}"; do
  spf_record+=" ip4:$ip"
done
spf_record+=" -all"

# 删除记录
aliyun alidns DescribeDomainRecords --DomainName ${domains[0]} --output cols=RecordId rows=DomainRecords.Record[] | awk 'NR>2 {print $1}' | xargs -I {} aliyun alidns DeleteDomainRecord --RecordId {}
# A记录
aliyun alidns AddDomainRecord \
--DomainName ${domains[0]} \
--RR "mail" \
--Type A \
--Value "${ips[0]}" \
--TTL 600

# TLS
docker run --rm \
  -v "${PWD}/docker-data/certbot/certs/:/etc/letsencrypt/" \
  -v "${PWD}/docker-data/certbot/logs/:/var/log/letsencrypt/" \
  -p 80:80 \
  --net=host \
  certbot/certbot certonly --standalone -d mail.${domains[0]} --agree-tos --no-eff-email --register-unsafely-without-email -v

# 安装DMS
DMS_GITHUB_URL="https://raw.githubusercontent.com/flyrenxing/DMS-install/main"
wget "${DMS_GITHUB_URL}/compose.yaml"
wget "${DMS_GITHUB_URL}/mailserver.env"
wget "${DMS_GITHUB_URL}/setup.sh"
chmod a+x ./setup.sh

# 替换配置信息
sed -i "s/example.com/${domains[0]}/g" compose.yaml
sed -i "s/ENABLE_RSPAMD=0/ENABLE_RSPAMD=1/g" mailserver.env
sed -i "s/ENABLE_OPENDKIM=1/ENABLE_OPENDKIM=0/g" mailserver.env

# 遍历域名进行操作
for DomainName in "${domains[@]}"; do
  # 删除记录
  aliyun alidns DescribeDomainRecords --DomainName $DomainName --output cols=RecordId rows=DomainRecords.Record[] | awk 'NR>2 {print $1}' | xargs -I {} aliyun alidns DeleteDomainRecord --RecordId {}

  echo "所有DNS记录已成功从阿里云删除。"

  # 添加SPF记录
  aliyun alidns AddDomainRecord --DomainName $DomainName --RR "@" --Type TXT --Value "$spf_record" --TTL 600

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
    --Value mail.${domains[0]} \
    --Priority 10 \
    --TTL 600
  # A记录
  aliyun alidns AddDomainRecord \
  --DomainName $DomainName \
  --RR "mail" \
  --Type A \
  --Value "${ips[0]}" \
  --TTL 600
  # 启动Docker Mail Server
  docker compose up -d

  # 添加邮箱账户和配置DKIM
  docker exec mailserver setup email add $Postmaster@${DomainName} 6c9W9LM65eGjM7tmHv
  docker exec mailserver setup config dkim keysize 1024 domain $DomainName
  # 玄学
  sleep 5
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

  # 要添加的域名和相关配置
  NEW_DOMAIN="${DomainName}"
  NEW_PATH="/tmp/docker-mailserver/rspamd/dkim/rsa-1024-mail-${DomainName}.private.txt"
  NEW_SELECTOR="mail"

  # 文件路径
  CONFIG_FILE="/root/docker-mailserver/docker-data/dms/config/rspamd/override.d/dkim_signing.conf"

  # 检查域名是否已经存在
  if grep -q "$NEW_DOMAIN" "$CONFIG_FILE"; then
      echo "Domain $NEW_DOMAIN already exists in the configuration file."
  else
      # 添加新的域名配置
      sed -i "/^domain {/a \ \ \ \ $NEW_DOMAIN {\n\ \ \ \ \ \ \ \ path = \"$NEW_PATH\";\n\ \ \ \ \ \ \ \ selector = \"$NEW_SELECTOR\";\n\ \ \ \ }" "$CONFIG_FILE"
      echo "Domain $NEW_DOMAIN added to the configuration file."
  fi

  echo "完成 ${DomainName} 配置！！！"
done

echo "全部域名处理完成。"

#复制/docker-data/dms/config/rspamd/override.d/dkim_signing.conf到容器/etc/rspamd/override.d/dkim_signing.conf
docker cp /root/docker-mailserver/docker-data/dms/config/rspamd/override.d/dkim_signing.conf mailserver:/etc/rspamd/override.d/dkim_signing.conf
docker exec -it mailserver sh -c 'echo "initial_destination_concurrency = 100000" >> /etc/postfix/main.cf'
docker exec -it mailserver sh -c 'echo "default_destination_concurrency_limit = 100000" >> /etc/postfix/main.cf'
docker exec -it mailserver sh -c 'echo "default_process_limit = 100000" >> /etc/postfix/main.cf'
docker compose restart

echo "Docker Mail Server 安装完成。"

for DomainName in "${domains[@]}"; do
  echo mail.${domains[0]},587,tls,$Postmaster@${DomainName},6c9W9LM65eGjM7tmHv
done