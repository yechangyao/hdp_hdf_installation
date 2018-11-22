#!/usr/bin/env bash
# Launch Centos/RHEL 7 VM with at least 8 vcpu / 32Gb+ memory / 100Gb disk
# Then run:
# curl -sSL https://gist.github.com/abajwa-hw/2050a71363f14a59bc19c6697cb78a1f/raw | sudo -E sh  

export create_image=${create_image:-false}
export ambari_version=2.7.1.0
export mpack_url="http://public-repo-1.hortonworks.com/HDF/centos7/3.x/updates/3.2.0.0/tars/hdf_ambari_mp/hdf-ambari-mpack-3.2.0.0-520.tar.gz"  
export hdf_vdf="http://s3.amazonaws.com/public-repo-1.hortonworks.com/HDF/centos7/3.x/updates/3.2.0.0/HDF-3.2.0.0-520.xml"

export bp_template="https://gist.github.com/abajwa-hw/691d1e97b5b61c5be7ec4acb383d0de4/raw"
#export hdf_repo="http://public-repo-1.hortonworks.com/HDF/centos7/3.x/updates/3.2.0.0/hdf.repo"
export hdf_version="3.2.0.0-520"


export ambari_password=${ambari_password:-StrongPassword}
export db_password=${db_password:-StrongPassword}
export nifi_flow="https://gist.githubusercontent.com/abajwa-hw/3857a205d739473bb541490f6471cdba/raw"
export install_solr=${install_solr:-false}    ## for Twitter demo
export host=$(hostname -f)

export ambari_services="HDFS MAPREDUCE2 YARN ZOOKEEPER DRUID SUPERSET STREAMLINE NIFI NIFI_REGISTRY KAFKA STORM REGISTRY HBASE PHOENIX ZEPPELIN"
export cluster_name=Whoville
export ambari_stack_version=3.0
export host_count=1
#service user for Ambari to setup demos
export service_user="demokitadmin"
export service_password="BadPass#1"

if [ "${create_image}" = true  ]; then
  echo "updating /etc/hosts with demo.hortonworks.com entry pointing to VMs ip, hostname..."
  curl -sSL https://gist.github.com/abajwa-hw/9d7d06b8d0abf705ae311393d2ecdeec/raw | sudo -E sh 
  sleep 5
fi

export host=$(hostname -f)
echo "Hostname is: ${host}"



echo Installing Packages...
sudo yum localinstall -y https://dev.mysql.com/get/mysql57-community-release-el7-8.noarch.rpm
sudo yum install -y git python-argparse epel-release mysql-connector-java* mysql-community-server nc
# MySQL Setup to keep the new services separate from the originals
echo Database setup...
sudo systemctl enable mysqld.service
sudo systemctl start mysqld.service
#extract system generated Mysql password
oldpass=$( grep 'temporary.*root@localhost' /var/log/mysqld.log | tail -n 1 | sed 's/.*root@localhost: //' )
#create sql file that
# 1. reset Mysql password to temp value and create druid/superset/registry/streamline schemas and users
# 2. sets passwords for druid/superset/registry/streamline users to ${db_password}
cat << EOF > mysql-setup.sql
ALTER USER 'root'@'localhost' IDENTIFIED BY 'Secur1ty!'; 
uninstall plugin validate_password;
CREATE DATABASE druid DEFAULT CHARACTER SET utf8; CREATE DATABASE superset DEFAULT CHARACTER SET utf8; CREATE DATABASE registry DEFAULT CHARACTER SET utf8; CREATE DATABASE streamline DEFAULT CHARACTER SET utf8; 
CREATE USER 'druid'@'%' IDENTIFIED BY '${db_password}'; CREATE USER 'superset'@'%' IDENTIFIED BY '${db_password}'; CREATE USER 'registry'@'%' IDENTIFIED BY '${db_password}'; CREATE USER 'streamline'@'%' IDENTIFIED BY '${db_password}'; 
GRANT ALL PRIVILEGES ON *.* TO 'druid'@'%' WITH GRANT OPTION; GRANT ALL PRIVILEGES ON *.* TO 'superset'@'%' WITH GRANT OPTION; GRANT ALL PRIVILEGES ON registry.* TO 'registry'@'%' WITH GRANT OPTION ; GRANT ALL PRIVILEGES ON streamline.* TO 'streamline'@'%' WITH GRANT OPTION ; 
commit; 
EOF
#execute sql file
mysql -h localhost -u root -p"$oldpass" --connect-expired-password < mysql-setup.sql
#change Mysql password to ${db_password}
mysqladmin -u root -p'Secur1ty!' password ${db_password}
#test password and confirm dbs created
mysql -u root -p${db_password} -e 'show databases;'
# Install Ambari
echo Installing Ambari

export install_ambari_server=true
#export java_provider=oracle
curl -sSL https://raw.githubusercontent.com/abajwa-hw/ambari-bootstrap/master/ambari-bootstrap.sh | sudo -E sh
sudo ambari-server setup --jdbc-db=mysql --jdbc-driver=/usr/share/java/mysql-connector-java.jar
sudo ambari-server install-mpack --verbose --mpack=${mpack_url}
# Hack to fix a current bug in Ambari Blueprints
sudo sed -i.bak "s/\(^    total_sinks_count = \)0$/\11/" /var/lib/ambari-server/resources/stacks/HDP/2.0.6/services/stack_advisor.py

#echo "Creating Storm View..."
#curl -u admin:admin -H "X-Requested-By:ambari" -X POST -d '{"ViewInstanceInfo":{"instance_name":"Storm_View","label":"Storm View","visible":true,"icon_path":"","icon64_path":"","description":"storm view","properties":{"storm.host":"'${host}'","storm.port":"8744","storm.sslEnabled":"false"},"cluster_type":"NONE"}}' http://${host}:8080/api/v1/views/Storm_Monitoring/versions/0.1.0/instances/Storm_View

#create demokitadmin user
curl -iv -u admin:admin -H "X-Requested-By: blah" -X POST -d "{\"Users/user_name\":\"${service_user}\",\"Users/password\":\"${service_password}\",\"Users/active\":\"true\",\"Users/admin\":\"true\"}" http://localhost:8080/api/v1/users

echo "Updating admin password..."
curl -iv -u admin:admin -H "X-Requested-By: blah" -X PUT -d "{ \"Users\": { \"user_name\": \"admin\", \"old_password\": \"admin\", \"password\": \"${ambari_password}\" }}" http://localhost:8080/api/v1/users/admin

cd /tmp

#solr pre-restart steps
if [ "${install_solr}" = true  ]; then
	sudo git clone https://github.com/abajwa-hw/solr-stack.git   /var/lib/ambari-server/resources/stacks/HDP/${ambari_stack_version}/services/SOLRDEMO
   cat << EOF > custom_order.json
    "SOLR_MASTER-START" : ["ZOOKEEPER_SERVER-START"],
EOF

   sudo sed -i.bak '/"dependencies for all cases",/ r custom_order.json' /var/lib/ambari-server/resources/stacks/HDP/2.5/role_command_order.json
   
   solr_config="\"solr-config\": { \"solr.download.location\": \"HDPSEARCH\", \"solr.cloudmode\": \"true\", \"solr.demo_mode\": \"true\" },"	
   echo ${solr_config} > solr-config.json
fi

sudo ambari-server restart

tee /tmp/repo.json > /dev/null << EOF
{
  "Repositories": {
    "base_url": "http://public-repo-1.hortonworks.com/HDF/centos7/3.x/updates/3.2.0.0",
    "verify_base_url": true,
    "repo_name": "HDF"
  }
}
EOF

##testing changes
#url="http://localhost:8080/api/v1/stacks/HDP/versions/2.6/operating_systems/redhat7/repositories/HDF-3.0"
#curl -L -H X-Requested-By:blah -u admin:${ambari_password} -X PUT "${url}" -d @/tmp/repo.json
#curl -L -H X-Requested-By:blah -u admin:${ambari_password} "${url}"
#
curl -v -k -u admin:${ambari_password} -H "X-Requested-By:ambari" -X POST http://localhost:8080/api/v1/version_definitions -d @- <<EOF
{  "VersionDefinition": {   "version_url": "${hdf_vdf}" } }
EOF

#wget ${hdf_repo} -P /etc/yum.repos.d/  

sudo ambari-server restart

# Ambari blueprint cluster install
echo "Deploying HDP and HDF services..."
curl -ssLO https://github.com/seanorama/ambari-bootstrap/archive/master.zip
unzip -q master.zip -d  /tmp

export host=$(hostname -f)
cd /tmp
echo "downloading twitter flow..."
twitter_flow=$(curl -L ${nifi_flow})
#change kafka broker string for Ambari to replace later
twitter_flow=$(echo ${twitter_flow}  | sed "s/demo.hortonworks.com/${host}/g")
nifi_config="\"nifi-flow-env\" : { \"properties_attributes\" : { }, \"properties\" : { \"content\" : \"${twitter_flow}\"  }  },"
echo ${nifi_config} > nifi-config.json


echo "downloading Blueprint configs template..."
curl -sSL ${bp_template} > configuration-custom-template.json

echo "adding Nifi flow to blueprint configs template..."
sed -e "2r nifi-config.json" configuration-custom-template.json  > configuration-custom.json


if [ "${install_solr}" = true  ]; then
  echo "adding Solr to blueprint configs template..."
  sed -e "2r solr-config.json" configuration-custom.json > configuration-custom-solr.json
  sudo mv configuration-custom.json configuration-custom-nifi.json
  sudo mv configuration-custom-solr.json configuration-custom.json
  
  export ambari_services="${ambari_services} SOLR"
fi


if [ "${create_image}" = true  ]; then
  echo "Setting up auto start of services on boot"
  curl -sSL https://gist.github.com/abajwa-hw/408134e032c05d5ff7e592cd0770d702/raw | sudo -E sh
fi


cd /tmp/ambari-bootstrap-master/deploy
sudo cp /tmp/configuration-custom.json .

#export deploy=false

# This command might fail with 'resources' error, means Ambari isn't ready yet
echo "Waiting for 90s before deploying cluster with services: ${ambari_services}"
sleep 90
sudo -E /tmp/ambari-bootstrap-master/deploy/deploy-recommended-cluster.bash

#sleep 5
#cd /tmp/ambari-bootstrap-master/deploy/tempdir*
#sed -i.bak '3i\  "repository_version_id": 1,\' cluster.json
#echo "updated cluster.json:"
#head cluster.json
#curl -ksSu admin:${ambari_password} -H x-requested-by:ambari http://localhost:8080/api/v1/blueprints/recommended -d @blueprint.json
#curl -ksSu admin:${ambari_password} -H x-requested-by:ambari http://localhost:8080/api/v1/clusters/${cluster_name} -d @cluster.json

#exit 1

echo Now open your browser to http://$(curl -s icanhazptr.com):8080 and login as admin/${ambari_password} to observe the cluster install

echo "Waiting for cluster to be installed..."
sleep 5

#wait until cluster deployed
ambari_pass="${ambari_password}" source /tmp/ambari-bootstrap-master/extras/ambari_functions.sh
ambari_configs
ambari_wait_request_complete 1

sleep 10
