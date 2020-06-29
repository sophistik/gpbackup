#!/bin/bash

set -ex

ccp_src/scripts/setup_ssh_to_cluster.sh
ssh -t centos@mdw "curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscli.zip" && \
    unzip -qq awscli.zip && \
    sudo ./aws/install && \
    sudo yum install -y apr libevent-devel"

out=$(ssh -t mdw 'source env.sh && psql postgres -c "select version();"')
GPDB_VERSION=$(echo ${out} | sed -n 's/.*Greenplum Database \([0-9]\).*/\1/p')
mkdir -p /tmp/untarred
tar -xzf gppkgs/gpbackup-gppkgs.tar.gz -C /tmp/untarred
scp /tmp/untarred/gpbackup_tools*gp${GPDB_VERSION}*${OS}*.gppkg mdw:/home/gpadmin
ssh -t mdw "source env.sh; gppkg -i gpbackup_tools*.gppkg"

cat << EOF > lineitem.ddl
CREATE TABLE lineitem (
    l_orderkey       INTEGER NOT NULL,
    l_partkey        INTEGER NOT NULL,
    l_suppkey        INTEGER NOT NULL,
    l_linenumber     INTEGER NOT NULL,
    l_quantity       DECIMAL(15,2) NOT NULL,
    l_extendedprice  DECIMAL(15,2) NOT NULL,
    l_discount       DECIMAL(15,2) NOT NULL,
    l_tax            DECIMAL(15,2) NOT NULL,
    l_returnflag     CHAR(1) NOT NULL,
    l_linestatus     CHAR(1) NOT NULL,
    l_shipdate       DATE NOT NULL,
    l_commitdate     DATE NOT NULL,
    l_receiptdate    DATE NOT NULL,
    l_shipinstruct   CHAR(25) NOT NULL,
    l_shipmode       CHAR(10) NOT NULL,
    l_comment        VARCHAR(44) NOT NULL
)
DISTRIBUTED BY (l_orderkey);
EOF

cat << EOF > gpload.yml
---
VERSION: 1.0.0.1
DATABASE: tpchdb
USER: gpadmin
HOST: localhost
PORT: ${PG_PORT}
GPLOAD:
   INPUT:
    - SOURCE:
         FILE:
           - /data/gpdata/lineitem_${SCALE_FACTOR}.tbl
    - FORMAT: text
    - DELIMITER: '|'
    - HEADER: false
   OUTPUT:
    - TABLE: lineitem
    - MODE: insert
    - UPDATE_CONDITION: 'boolean_condition'
   PRELOAD:
    - TRUNCATE: true
    - REUSE_TABLES: false
EOF

cat <<SCRIPT > /tmp/setup_perf.bash
#!/bin/bash

set -ex
source env.sh
TIMEFORMAT=%R

function print_header() {
    header="### \$1 ###"
    len=\$(echo \$header | awk '{print length}')
    printf "%0.s#" \$(seq 1 \$len) && echo
    echo -e "\$header"
    printf "%0.s#" \$(seq 1 \$len) && echo
}

mkdir -p /home/gpadmin/.aws
cat << CRED > \${HOME}/.aws/credentials
[default]
aws_access_key_id=${AWS_ACCESS_KEY_ID}
aws_secret_access_key=${AWS_SECRET_ACCESS_KEY}
CRED
chmod 400 \${HOME}/.aws/credentials
aws s3 cp s3://${BUCKET}/benchmark/tpch/lineitem/${SCALE_FACTOR}/lineitem.tbl /data/gpdata/lineitem_${SCALE_FACTOR}.tbl

# Create tpch dataset
createdb tpchdb
psql -d tpchdb -a -f lineitem.ddl
gpload -f gpload.yml

set +x
COUNT=150
print_header "CREATE tpchdb with \${COUNT} lineitem tables each with ${SCALE_FACTOR} GB"
for i in {1..150}
do
  psql -d tpchdb -c "CREATE TABLE lineitem_\$i AS SELECT * FROM lineitem DISTRIBUTED BY (l_orderkey)"
#  pids+=" $!"
done
#wait $pids || { echo "errors" >&2; exit 1; }
set -x

SCRIPT

chmod +x /tmp/setup_perf.bash
scp lineitem.ddl gpload.yml /tmp/setup_perf.bash mdw:
ssh -t mdw "/home/gpadmin/setup_perf.bash"
