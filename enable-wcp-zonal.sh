#!/usr/bin/bash

###################################################
# Enter temp variables here
###################################################

VCENTER_VERSION=8
VCENTER_HOSTNAME=192.168.100.50
VCENTER_USERNAME=administrator@vsphere.local
VCENTER_PASSWORD='VMware1!'

export AVI_CLOUD='domain-c99'
export AVI_HOSTNAME=192.168.100.58
export AVI_USERNAME=admin
export AVI_PASSWORD='VMware1!'

# export NSX_INGRESS_CIDR='10.220.3.16'
# export NSX_EGRESS_CIDR=10.220.30.80
# export NSX_EDGE_CLUSTER_ID='f98c44c3-131b-4f3d-811f-95edc1b00b86'
# export NSX_TO_GATEWAY='nsxt01-t0-tr'
# export NSX_NAMESPACE_NETWORK='10.244.0.0'
# export NSX_VDS='50 01 79 90 7e 9c 73 51-ad af 31 fa 15 49 8d e0'

K8S_SUP_ZONE1='zone1'
K8S_SUP_ZONE2='zone2'
K8S_SUP_ZONE3='zone3'
K8S_CONTENT_LIBRARY=utkg
K8S_STORAGE_POLICY=tanzu
K8S_MGMT_PORTGROUP1='DVPG-Management-network-1'
K8S_MGMT_PORTGROUP2='DVPG-Management-network-2'
K8S_MGMT_PORTGROUP3='DVPG-Management-network-3'
K8S_WKD0_PORTGROUP='Workload0-VDS-PG' #NOT NEEDED FOR NSX

###################################################

HEADER_CONTENTTYPE="Content-Type: application/json"

content_library_json()
{
	cat <<EOF
{
	"name": "${K8S_CONTENT_LIBRARY}"
}
EOF
}

rm -f /tmp/temp_*.*
cp sample-zonal-vds-80u3.json zonal.json

################################################
# Get NSXALB CA CERT
###############################################
echo "Getting NSX ALB CA Certificate for  ${AVI_HOSTNAME} ..."
openssl s_client -showcerts -connect ${AVI_HOSTNAME}:443  </dev/null 2>/dev/null|sed -ne '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > /tmp/temp_avi-ca.cert
if [ ! -s /tmp/temp_avi-ca.cert ]
then
    echo "Error: Could not connect to the NSX ALB endpoint. Please validate!!"
    exit 1
fi
export AVI_CACERT=$(jq -sR . /tmp/temp_avi-ca.cert)

################################################
# Login to VCenter and get Session ID
###############################################
SESSION_ID=$(curl -sk -X POST https://${VCENTER_HOSTNAME}/rest/com/vmware/cis/session --user ${VCENTER_USERNAME}:${VCENTER_PASSWORD} |jq -r '.value')
if [ -z "${SESSION_ID}" ]
then
	echo "Error: Could not connect to the VCenter. Please validate!!"
	exit 1
fi
echo Authenticated successfully to VC with Session ID - ${SESSION_ID} ...
HEADER_SESSIONID="vmware-api-session-id: ${SESSION_ID}"

################################################
# Get zone details from vCenter
###############################################
echo "Searching for Zones ..."
response=$(curl -ks --write-out "%{http_code}" -X GET  -H "${HEADER_SESSIONID}" https://${VCENTER_HOSTNAME}/api/vcenter/consumption-domains/zones --output /tmp/temp_zones.json)
if [[ "${response}" -ne 200 ]] ; then
  echo "Error: Could not fetch zones. Please validate!!"
  exit 1
fi

export TKGZone1=$(jq -r --arg K8S_SUP_ZONE1 "$K8S_SUP_ZONE1" '.items[]|select(.zone == $K8S_SUP_ZONE1).zone' /tmp/temp_zones.json)
if [ -z "${TKGZone1}" ]
then
        echo "Error: Could not fetch zone - ${K8S_SUP_ZONE1} . Please validate!!"
        exit 1
fi
export TKGZone2=$(jq -r --arg K8S_SUP_ZONE2 "$K8S_SUP_ZONE2" '.items[]|select(.zone == $K8S_SUP_ZONE2).zone' /tmp/temp_zones.json)
if [ -z "${TKGZone2}" ]
then
        echo "Error: Could not fetch zone - ${K8S_SUP_ZONE2} . Please validate!!"
        exit 1
fi
export TKGZone3=$(jq -r --arg K8S_SUP_ZONE3 "$K8S_SUP_ZONE3" '.items[]|select(.zone == $K8S_SUP_ZONE3).zone' /tmp/temp_zones.json)
if [ -z "${TKGZone3}" ]
then
        echo "Error: Could not fetch zone - ${K8S_SUP_ZONE3} . Please validate!!"
        exit 1
fi

# If Supervisor enabled on the cluster, error out
#then
#        echo "Error: Supervisor already enabled on - ${K8S_SUP_CLUSTER}. Exiting!!"
#        exit 1
#fi

################################################
# Get contentlibrary details from vCenter
###############################################

echo "Searching for Content Library ${K8S_CONTENT_LIBRARY} ..."
response=$(curl -ks --write-out "%{http_code}" -X POST -H "${HEADER_SESSIONID}" -H "${HEADER_CONTENTTYPE}" -d "$(content_library_json)" https://${VCENTER_HOSTNAME}/api/content/library?action=find --output /tmp/temp_contentlib.json)
if [[ "${response}" -ne 200 ]] ; then
	echo "Error: Could not fetch content librarys. Please validate!!"
	exit 1
fi

export TKGContentLibrary=$(jq -r '.[]' /tmp/temp_contentlib.json)
if [ -z "${TKGContentLibrary}" ]
then
   	echo "Error: Could not fetch content library - ${K8S_CONTENT_LIBRARY} . Please validate!!"
   	exit 1
fi

################################################
# Get stroage policy details from vCenter
###############################################
echo "Searching for Storage Policy ${K8S_STORAGE_POLICY} ..."
response=$(curl -ks --write-out "%{http_code}" -X GET  -H "${HEADER_SESSIONID}" https://${VCENTER_HOSTNAME}/api/vcenter/storage/policies --output /tmp/temp_storagepolicies.json)
if [[ "${response}" -ne 200 ]] ; then
  echo "Error: Could not fetch storage policy. Please validate!!"
  exit 1
fi

export TKGStoragePolicy=$(jq -r --arg K8S_STORAGE_POLICY "$K8S_STORAGE_POLICY" '.[]| select(.name == $K8S_STORAGE_POLICY)|.policy' /tmp/temp_storagepolicies.json)
#export TKGStoragePolicy=$(jq -r --arg K8S_STORAGE_POLICY "$K8S_STORAGE_POLICY" '.[]| select(.name|contains($K8S_STORAGE_POLICY))|.policy' /tmp/temp_storagepolicies.json)
if [ -z "${TKGStoragePolicy}" ]
then
        echo "Error: Could not fetch storage policy - ${K8S_STORAGE_POLICY} . Please validate!!"
        exit 1
fi

################################################
# Get network details from vCenter
###############################################
echo "Searching for Network portgroups  ..."
response=$(curl -ks --write-out "%{http_code}" -X GET  -H "${HEADER_SESSIONID}" https://${VCENTER_HOSTNAME}/api/vcenter/network --output /tmp/temp_networkportgroups.json)
if [[ "${response}" -ne 200 ]] ; then
  echo "Error: Could not fetch network details. Please validate!!"
  exit 1
fi

export TKGMgmtNetwork1=$(jq -r --arg K8S_MGMT_PORTGROUP1 "$K8S_MGMT_PORTGROUP1" '.[]| select(.name == $K8S_MGMT_PORTGROUP1)|.network' /tmp/temp_networkportgroups.json)
export TKGMgmtNetwork2=$(jq -r --arg K8S_MGMT_PORTGROUP2 "$K8S_MGMT_PORTGROUP2" '.[]| select(.name == $K8S_MGMT_PORTGROUP2)|.network' /tmp/temp_networkportgroups.json)
export TKGMgmtNetwork3=$(jq -r --arg K8S_MGMT_PORTGROUP3 "$K8S_MGMT_PORTGROUP3" '.[]| select(.name == $K8S_MGMT_PORTGROUP3)|.network' /tmp/temp_networkportgroups.json)
export TKGWorkload0Network=$(jq -r --arg K8S_WKD0_PORTGROUP "$K8S_WKD0_PORTGROUP" '.[]| select(.name == $K8S_WKD0_PORTGROUP)|.network' /tmp/temp_networkportgroups.json)
if [ -z "${TKGMgmtNetwork1}" ]
then
        echo "Error: Could not fetch portgroup - ${K8S_MGMT_PORTGROUP1} . Please validate!!"
        exit 1
fi
if [ -z "${TKGMgmtNetwork2}" ]
then
        echo "Error: Could not fetch portgroup - ${K8S_MGMT_PORTGROUP2} . Please validate!!"
        exit 1
fi
if [ -z "${TKGMgmtNetwork3}" ]
then
        echo "Error: Could not fetch portgroup - ${K8S_MGMT_PORTGROUP3} . Please validate!!"
        exit 1
fi
if [ -z "${TKGWorkload0Network}" ]
then
        echo "Error: Could not fetch portgroup - ${K8S_WKD0_PORTGROUP} . Please validate!!"
        exit 1
fi
if [ -z "${TKGWorkload1Network}" ]
then
        echo "Error: Could not fetch portgroup - ${K8S_WKD0_PORTGROUP} . Please validate!!"
        exit 1
fi

################################################
# Get cluster details from vCenter
###############################################
envsubst < zonal.json > temp_final.json

echo "Enabling Supervisor ..."
curl -ks -X POST -H "${HEADER_SESSIONID}" -H "${HEADER_CONTENTTYPE}" -d "@temp_final.json" https://${VCENTER_HOSTNAME}/api/vcenter/namespace-management/supervisors?action=enable_on_zones

#TODO while configuring, keep checking for status of Supervisor until ready

rm -f /tmp/temp_*.*
rm -f temp_final.json
rm -f zonal.json