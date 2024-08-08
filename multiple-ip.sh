#!/bin/bash

DomainName=$1
IPFilePath=$2

# 清除已有的POSTROUTING规则，防止重复添加
iptables -t nat -F POSTROUTING

# 读取IP地址数组
mapfile -t ips < "$IPFilePath"

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

# 删除所有记录
aliyun alidns DescribeDomainRecords --DomainName $DomainName --output cols=RecordId rows=DomainRecords.Record[] | awk 'NR>2 {print $1}' | xargs -I {} aliyun alidns DeleteDomainRecord --RecordId {}

# 添加SPF记录
aliyun alidns AddDomainRecord --DomainName $DomainName --RR "@" --Type TXT --Value "$spf_record" --TTL 600

# A记录
aliyun alidns AddDomainRecord \
  --DomainName $DomainName \
  --RR "mail" \
  --Type A \
  --Value "${ips[0]}" \
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

DkimRecord=$(cat rsa-1024-mail-${DomainName}.public.dns.txt)

# DKIM 记录
aliyun alidns AddDomainRecord \
  --DomainName $DomainName \
  --RR "mail._domainkey" \
  --Type TXT \
  --Value "$DkimRecord" \
  --TTL 600