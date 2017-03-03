#!/bin/bash
#[ "$1" = -x ] && shift && set -x
# vi:set ts=3 sw=3:
# == Module: Open Telekom Cloud Cli Interface 0.7.x
#
# Manage OTC via Command Line
#
# === Parameters
#
# === Variables
#
# Recognized variables from environment:
#
# BANDWIDTH
#  set to default value "25" if unset
# VOLUMETYPE
#  set to default value "SATA" if unset
# APILIMIT
#  Either an integer, limiting the number of API results per call, or "off", removing limits.
#  If unset, default limits are used (different among API calls), can be overridden by --limit NNN.
# MAXGETKB
#  The maximum size for API (GET) response size that the API gateway allows without cutting it
#  if off (and thus breaking it for https). otc.sh tries to auto-paginate here ...
#
# === Examples
#
# Examples
# See help ...
#
# === Authors
#
# Zsolt Nagy <Z.Nagy@t-systems.com>
# Kurt Garloff <t-systems@garloff.de>
# Christian Kortwich <christian.kortwich@t-systems.com>
#
# === Copyright
#
# Copyright 2016 T-Systems International GmbH
# License: CC-BY-SA 3.0
#

VERSION=0.7.6

# Get Config ####################################################################
warn_too_open()
{
	PERM=$(stat -Lc "%a" "$1")
	if test "${PERM:2:1}" != "0"; then
		echo "Warning: $1 permissions too open ($PERM)" 1>&2
	fi
}

may_read_env_files()
{
	for file in "$@"; do
		if test -r "$file"; then
			echo "Note: Reading environment from $file ..." 1>&2
			source "$file"
			warn_too_open "$file"
			if test -n "$OS_PASSWORD" -a -n "$OS_USERNAME"; then break; fi
		fi
	done
}

otc_dir="$(dirname "$0")"
# Parse otc-tools specific config file (deprecated)
if test -r ~/.otc_env.sh; then
	source ~/.otc_env.sh
	warn_too_open ~/.otc_env.sh
#else
#	echo "Note: No ~/.otc_env.sh found, no defaults for ECS creation" 1>&2
fi
# Parse standard OpenStack environment setting files if needed
if test -z "$OS_PASSWORD" -o -z "$OS_USERNAME"; then
	may_read_env_files ~/.ostackrc.$OTC_TENANT ~/.ostackrc ~/.novarc ~/novarc
fi
# Defaults
if test -z "$OS_USER_DOMAIN_NAME"; then
	export OS_USER_DOMAIN_NAME="${OS_USERNAME##* }"
fi
if test -n "$OS_AUTH_URL"; then
	REG=${OS_AUTH_URL#*://}
	REG=${REG#*.}
	if test -z "$OS_REGION_NAME"; then
		export OS_REGION_NAME=${OS_REGION_NAME%%.*}
	fi
	REG=${REG#*.}
	export OS_CLOUD_ENV=${REG%%.*}
fi
if test -z "$OS_PROJECT_NAME"; then
	export OS_PROJECT_NAME="$OS_REGION_NAME"
fi
if test -z "$MAXGETKB"; then
	export MAXGETKB=251
fi
# S3 environment
if test -z "$S3_ACCESS_KEY_ID" -a -r ~/.s3rc.$OTC_TENANT; then
	echo "Note: Reading S3 environment from ~/.s3rc.$OTC_TENANT ..." 1>&2
	source ~/.s3rc.$OTC_TENANT
	warn_too_open ~/.s3rc.$OTC_TENANT
fi
if test -z "$S3_ACCESS_KEY_ID" -a -r ~/.s3rc; then
	echo "Note: Reading S3 environment from ~/.s3rc ..." 1>&2
	source ~/.s3rc
	warn_too_open ~/.s3rc
fi
# Alternatively parse CSV as returned by OTC
if test -r ~/credentials-$OTC_TENANT.csv; then
	CRED=credentials-$OTC_TENANT.csv
else
	CRED=credentials.csv
fi
if test -z "$S3_ACCESS_KEY_ID" -a -r ~/$CRED; then
	echo -n "Note: Parsing S3 $CRED ... " 1>&2
	LN=$(tail -n1 ~/$CRED | sed 's/"//g')
	UNM=${LN%%,*}
	LN=${LN#*,}
	if test "$UNM" = "$OS_USERNAME"; then
		echo "succeeded" 1>&2
		export S3_ACCESS_KEY_ID="${LN%,*}"
		export S3_SECRET_ACCESS_KEY="${LN#*,}"
	else
		echo "user mismatch \"$UNM\" != \"$OS_USERNAME\"" 1>&2
	fi
	warn_too_open ~/$CRED
fi

if test -z "$OS_USERNAME" -o -z "$OS_PASSWORD"; then
	echo "ERROR: Need to set OS_USERNAME, OS_PASSWORD, and OS_PROJECT_NAME environment" 1>&2
	echo " Optionally: OS_CACERT, HTTPS_PROXY, S3_ACCESS_KEY_ID, and S3_SECRET_ACCESS_KEY" 1>&2
	exit 1
fi

# ENVIROMENT SETTINGS ####################################################################

# Defaults
if test -z "$BANDWIDTH"; then BANDWIDTH=25; fi
if test -z "$VOLUMETYPE"; then VOLUMETYPE="SATA"; fi

test -n "$S3_HOSTNAME" || export S3_HOSTNAME=obs.otc.t-systems.com

if test -n "$OS_AUTH_URL"; then
	if [[ "$OS_AUTH_URL" = *"/v3" ]]; then
		export IAM_AUTH_URL="$OS_AUTH_URL/auth/tokens"
	else
		export IAM_AUTH_URL="$OS_AUTH_URL/tokens"
	fi
else
	export IAM_AUTH_URL="https://iam.${OS_REGION_NAME}.otc.t-systems.com/v3/auth/tokens"
fi

# REST call curl wrappers ###########################################################

# Generic wrapper to facilitate debugging
docurl()
{
	if test -n "$DEBUG"; then
		echo DEBUG: curl $INS "$@" | sed -e 's/X-Auth-Token: MII[^ ]*/X-Auth-Token: MIIsecretsecret/g' -e 's/"password": "[^"]*"/"password": "SECRET"/g' 1>&2
		if test "$DEBUG" = "2"; then
			TMPHDR=`mktemp /tmp/curlhdr.$$.XXXXXXXXXX`
			ANS=`curl $INS -D $TMPHDR "$@"`
			echo -n "DEBUG: Header" 1>&2
			cat $TMPHDR  | sed 's/X-Subject-Token: MII.*$/X-Subject-Token: MIIsecretsecret/' 1>&2
			rm $TMPHDR
		else
			ANS=`curl $INS "$@"`
		fi
		echo "DEBUG: $ANS" | sed 's/X-Subject-Token: MII.*$/X-Subject-Token: MIIsecretsecret/' 1>&2
		echo "$ANS"
	else
		curl $INS "$@"
	fi
}

curlpost()
{
	docurl -i -sS -H "Content-Type: application/json" -d "$1" "$2"
}

curlpostauth()
{
	TKN="$1"; shift
	docurl -sS -X POST \
		-H "Content-Type: application/json" \
		-H "Accept: application/json" \
		-H "X-Auth-Token: $TKN" \
		-H "X-Language: en-us" \
		-d "$1" "$2"
}

curlputauth()
{
	TKN="$1"; shift
	docurl -sS -X PUT -H "Content-Type: application/json" -H "Accept: application/json" \
		-H "X-Auth-Token: $TKN" -d "$1" "$2"
}

curlputauthbinfile()
{
	TKN="$1"; shift
	docurl -sS -X PUT -H "Content-Type: application/octet-stream" \
		-H "X-Auth-Token: $TKN" -T "$1" "$2"
}

curlgetauth()
{
	TKN="$1"; shift
	docurl -sS -X GET -H "Content-Type: application/json" -H "Accept: application/json" \
		-H "X-Auth-Token: $TKN" -H "X-Language: en-us" "$1"
}

curlgetauth_pag()
{
   URL="$2"
   unset HASLIM
   echo "$URL" | grep -q  'limit=' && HASLIM=1
	#echo "$HASLIM $MAXGETKB $RECSZ" 1>&2
   if test -n "$HASLIM" -o -z "$MAXGETKB" -o "$MAXGETKB" == "off" -o -z "$RECSZ"; then curlgetauth "$@"; return; fi
	TKN="$1"
	unset HASPAR
	echo "$URL" | grep -q '?' && HASPAR=1
	#RECSZ, HDRSZ, ARRNM, IDFIELD
	LIM=$((($MAXGETKB*1024-$HDRSZ)/$RECSZ))
	if test "$HASPAR" == 1; then
		LIMPAR="&limit=$LIM"
	else
		LIMPAR="?limit=$LIM"
	fi
   TMPF=$(mktemp /tmp/otc.sh.$$.XXXXXXXX)
	MARKPAR=""
	NOANS=0; LASTNO=1
	while test $NOANS != $LASTNO -a $(($NOANS%$LIM)) == 0; do
		LASTNO=$NOANS
		docurl -sS -X GET -H "Content-Type: application/json" -H "Accept: application/json" \
			-H "X-Auth-Token: $TKN" -H "X-Language: en-us" "$URL$LIMPAR$MARKPAR" >>$TMPF
		ANS=$(cat $TMPF | jq -r ".${ARRNM}[] | .${IDFIELD}")
		NOANS=$(echo "$ANS" | wc -l)
		LAST=$(echo "$ANS" | tail -n1 | tr -d '"')
		MARKPAR="&marker=$LAST"
	done
	cat $TMPF
   rm $TMPF
}

curldeleteauth()
{
	TKN="$1"; shift
	docurl -sS -X DELETE -H "Accept: application/json" -H "X-Auth-Token: $TKN" "$1"
}

curldeleteauth_language()
{
	TKN="$1"; shift
	docurl -sS -X DELETE \
		-H "Content-Type: application/json" \
		-H "Accept: application/json" \
		-H "X-Language: en-us" \
		-H "X-Auth-Token: $TKN" "$1"
}

curlpatchauth()
{
	TKN="$1"; shift
	if test -z "$3"; then CTYPE="application/json"; else CTYPE="$3"; fi
	docurl -sS -X PATCH \
		-H "Content-Type: $CTYPE" \
		-H "Accept: application/json" \
		-H "X-Auth-Token: $TKN" \
		-d "$1" "$2"
}

# ARGS: TKN URL PATH OP VALUE [CONTENTTYPE]
curldopatch()
{
	TKN="$1"; shift
	#if test -z "$4"; then OP="remove"; else OP="$3"; VAL="\"value\": \"$4\", "; fi
	if test "$3" != "remove"; then VAL="\"value\": \"$4\", "; fi
	if test -z "$5"; then CTYPE="application/json"; else CTYPE="$5"; fi
	curlpatchauth "$TKN" "[{\"path\": \"$2\", $VAL\"op\": \"$3\"}]" "$1" "$CTYPE"
}

# ARGS: TKN URL PATH VALUE [CONTENTTYPE]
curladdorreplace()
{
	TKN="$1"; shift
	if test -z "$4"; then CTYPE="application/json"; else CTYPE="$4"; fi
	VAL=`curlgetauth "$TKN" "$1" | jq ".$2"`
	echo "DEBUG: /$2: $VAL -> $3" 1>&2
	if test "$VAL" = "null"; then
		if test -z "$3"; then
			echo "WARN: Nothing to do, /$2 already non-existent" 1>&2
		else
			curldopatch "$TKN" "$1" "/$2" "add" "$3" "$CTYPE"
		fi
	else
		if test -z "$3"; then
			curldopatch "$TKN" "$1" "/$2" "remove" "" "$CTYPE"
		else
			curldopatch "$TKN" "$1" "/$2" "replace" "$3" "$CTYPE"
		fi
	fi
}

curldeleteauthwithjsonparameter()
{
	# $1: TOKEN
	# $2: PARAMETER
	# $3: URI
	TKN="$1"; shift
	docurl -sS -X DELETE \
	-H "Content-Type: application/json" \
	-H "X-Language: en-us" \
	-H "X-Auth-Token: $TKN" -d "$1" "$2" | jq '.'
}

unset SUBNETAZ

##########################################################################################

#FUNCTIONS ###############################################################################

# Arguments CATALOGJSON SERVICETYPE
getcatendpoint() {
	SERVICE_EP=$(echo "$1" | jq "select(.type == \"$2\") | .endpoints[].url" | tr -d '"')
	if test "$SERVICE_EP" != "null"; then
		echo "$SERVICE_EP"
	fi
}

# Arguments: SERVICESJSON ENDPOINTSJSON SERVICETYPE PROJECTID
getendpoint() {
	SERVICE_ID=$(echo "$1" | jq ".services[] | select(.type == \"$3\" and .enabled == true) | .id")
	if test -z "$SERVICE_ID"; then return; fi
	SERVICE_EP=$(echo "$2" | jq ".endpoints[] | select(.service_id == $SERVICE_ID) | .url" | tr -d '"' | sed -e "s/\$(tenant_id)s/$4/g")
	echo "$SERVICE_EP"
}

# Arguments SERVICEJSON SERVICETYPE
getv2endpoint() {
	SERVICE_EP=$(echo "$1" | jq ".access.serviceCatalog[] | select(.type == \"$2\") | .endpoints[].publicURL" | tr -d '"')
	if test "$SERVICE_EP" != "null"; then
		echo "$SERVICE_EP"
	fi
}

# Get a token (and the project ID)
# TODO: Token caching ...
TROVE_OVERRIDE=0
IS_OTC=1
getIAMToken() {
	export BASEURL="${IAM_AUTH_URL/:443\///}" # remove :443 port when present
	BASEURL=${BASEURL%%/v[23]*}
   REQSCOPE=${1:-project}

   # Project by ID or by Name
	if test -n "$OS_PROJECT_ID"; then
		TENANT="\"tenantId\": \"$OS_PROJECT_ID\""
      PROJECT="\"project\": { \"id\": \"$OS_PROJECT_ID\" }"
   else
		TENANT="\"tenantName\": \"$OS_PROJECT_NAME\""
      PROJECT="\"project\": { \"name\": \"$OS_PROJECT_NAME\" }"
   fi
	# Token scope: project vs domain
	if test "$REQSCOPE" == "domain"; then
		SCOPE="\"scope\": { \"domain\": { \"name\": \"$OS_USER_DOMAIN_NAME\" } } "
	else
		SCOPE="\"scope\": { $PROJECT }"
   fi

	IAM2_REQ='{
			"auth": {
				'$TENANT',
				"passwordCredentials": {
					"username": "'"$OS_USERNAME"'",
					"password": "'"$OS_PASSWORD"'"
				}
			}
		}
	'
	IAM3_REQ='{
			"auth": {
			 "identity": {
				"methods": [ "password" ],
				 "password": {
					"user": {
						"name": "'"$OS_USERNAME"'",
						"password": "'"$OS_PASSWORD"'",
						"domain": { "name": "'"${OS_USER_DOMAIN_NAME}"'" }
					}
				 }
			 },
			 '$SCOPE'
			}
	}
	'
   if test -n "$OS_PROJECT_DOMAIN_NAME"; then IAM3_REQ=$(echo "$IAM3_REQ" | sed "/\"project\":/i\ \t\t\t\t\"domain\": { \"name\": \"$OS_PROJECT_DOMAIN_NAME\" },"); fi
	export IAM2_REQ IAM3_REQ
	#if test -n "$DEBUG"; then
	#	echo "curl $INS -d $IAM_REQ $IAM_AUTH_URL" | sed 's/"password": "[^"]*"/"password": "SECRET"/g' 1>&2
	#fi
	if [[ "$IAM_AUTH_URL" = *"v3/auth/tokens" ]]; then
		IAMRESP=`curlpost "$IAM3_REQ" "$IAM_AUTH_URL"`
		TOKEN=`echo "$IAMRESP" | grep "X-Subject-Token:" | cut -d' ' -f 2`
		#echo ${TOKEN} | sed -e 's/[0-9]/./g' -e 's/[a-z]/x/g' -e 's/[A-Z]/X/g'
		if test -z "$OS_PROJECT_ID"; then
			OS_PROJECT_ID=`echo "$IAMRESP" | tail -n1 | jq -r '.token.project.id'`
		fi
		if test -z "$TOKEN" -o -z "$OS_PROJECT_ID"; then
			echo "ERROR: Failed to authenticate and get token from $IAM_AUTH_URL for user $OS_USERNAME" 1>&2
			exit 2
		fi
		if test -z "$OS_USER_DOMAIN_ID"; then
			OS_USER_DOMAIN_ID=`echo "$IAMRESP" | getUserDomainIdFromIamResponse `
		fi
		if test -z "$OS_USER_DOMAIN_ID"; then
			echo "ERROR: Failed to determine user domain id from $IAM_AUTH_URL for user $OS_USERNAME" 1>&2
			exit 2
		fi
		# Parse IAM RESP catalogue
		CATJSON=$(echo "$IAMRESP" | tail -n1 | jq '.token.catalog[]')
		ROLEJSON=$(echo "$IAMRESP" | tail -n1 | jq '.token.roles[]')
		if test -n "$CATJSON" -a "$CATJSON" != "null"; then
			CINDER_URL=$(getcatendpoint "$CATJSON" volumev2 $OS_PROJECT_ID)
			NEUTRON_URL=$(getcatendpoint "$CATJSON" network $OS_PROJECT_ID)
			GLANCE_URL=$(getcatendpoint "$CATJSON" image $OS_PROJECT_ID)
			DESIGNATE_URL=$(getcatendpoint "$CATJSON" dns $OS_PROJECT_ID)
			NOVA_URL=$(getcatendpoint "$CATJSON" compute $OS_PROJECT_ID)
			HEAT_URL=$(getcatendpoint "$CATJSON" orchestration $OS_PROJECT_ID)
			TROVE_URL=$(getcatendpoint "$CATJSON" database $OS_PROJECT_ID)
			KEYSTONE_URL=$(getcatendpoint "$CATJSON" identity $OS_PROJECT_ID)
			CEILOMETER_URL=$(getcatendpoint "$CATJSON" metering $OS_PROJECT_ID)
			if test -n "$OUTPUT_CAT"; then echo "$CATJSON" | jq '.'; fi
			if test -n "$OUTPUT_ROLES"; then echo "$ROLEJSON" | jq '.'; fi
		else
			SERVICES="$(curlgetauth $TOKEN ${IAM_AUTH_URL%auth*}services)"
			ENDPOINTS="$(curlgetauth $TOKEN ${IAM_AUTH_URL%auth*}endpoints)"
			#if test "$?" != "0"; then
			#	echo "ERROR: No keystone v3 service catalog" 1>&2
			#	exit 2
			#fi
			CINDER_URL=$(getendpoint "$SERVICES" "$ENDPOINTS" volumev2 $OS_PROJECT_ID)
			NEUTRON_URL=$(getendpoint "$SERVICES" "$ENDPOINTS" network $OS_PROJECT_ID)
			GLANCE_URL=$(getendpoint "$SERVICES" "$ENDPOINTS" image $OS_PROJECT_ID)
			DESIGNATE_URL=$(getendpoint "$SERVICES" "$ENDPOINTS" dns $OS_PROJECT_ID)
			NOVA_URL=$(getendpoint "$SERVICES" "$ENDPOINTS" compute $OS_PROJECT_ID)
			HEAT_URL=$(getendpoint "$SERVICES" "$ENDPOINTS" orchestration $OS_PROJECT_ID)
			TROVE_URL=$(getendpoint "$SERVICES" "$ENDPOINTS" database $OS_PROJECT_ID)
			KEYSTONE_URL=$(getendpoint "$SERVICES" "$ENDPOINTS" identity $OS_PROJECT_ID)
			CEILOMETER_URL=$(getendpoint "$SERVICES" "$ENDPOINTS" metering $OS_PROJECT_ID)
		fi
      if test -n "$OUTPUT_DOM"; then echo "$IAMRESP" | tail -n1 | jq '.token.project.domain.id' | tr -d '"'; fi
	else
		IS_OTC=0
		IAMRESP=`curlpost "$IAM2_REQ" "$IAM_AUTH_URL"`
		IAMJSON=`echo "$IAMRESP" | tail -n1`
		TOKEN=`echo "$IAMJSON" | jq -r '.access.token.id' | tr -d '"'`
		if test -z "$OS_PROJECT_ID"; then
			OS_PROJECT_ID=`echo "$IAMJSON" | tail -n1 | jq -r '.access.token.tenant.id'`
		fi
		if test -z "$TOKEN" -o -z "$OS_PROJECT_ID"; then
			echo "ERROR: Failed to authenticate and get token from $IAM_AUTH_URL for user $OS_USERNAME" 1>&2
			exit 2
		fi
		CINDER_URL=$(getv2endpoint "$IAMJSON" volumev2 $OS_PROJECT_ID)
		NEUTRON_URL=$(getv2endpoint "$IAMJSON" network $OS_PROJECT_ID)
		GLANCE_URL=$(getv2endpoint "$IAMJSON" image $OS_PROJECT_ID)
		DESIGNATE_URL=$(getv2endpoint "$IAMJSON" dns $OS_PROJECT_ID)
		NOVA_URL=$(getv2endpoint "$IAMJSON" compute $OS_PROJECT_ID)
		HEAT_URL=$(getv2endpoint "$IAMJSON" orchestration $OS_PROJECT_ID)
		TROVE_URL=$(getv2endpoint "$IAMJSON" database $OS_PROJECT_ID)
		KEYSTONE_URL=$(getv2endpoint "$IAMJSON" identity $OS_PROJECT_ID)
		CEILOMETER_URL=$(getv2endpoint "$IAMJSON" metering $OS_PROJECT_ID)
	fi
	# FIXME: Delete this
	# For now fall back to hardcoded URLs
	if test -z "$NOVA_URL" -a "$IS_OTC" = "1" -a "$REQSCOPE" == "project"; then
		echo "WARN: Using hardcoded endpoints, will be removed" 1>&2
		CINDER_URL=${BASEURL/iam/evs}/v2/$OS_PROJECT_ID
		NEUTRON_URL=${BASEURL/iam/vpc}
		GLANCE_URL=${BASEURL/iam/ims}
		DESIGNATE_URL=${BASEURL/iam/dns}
		NOVA_URL=${BASEURL/iam/ecs}/v2/$OS_PROJECT_ID
		HEAT_URL=${BASEURL/iam/rts}/v1/$OS_PROJECT_ID
		TROVE_URL=${BASEURL/iam/rds}
	fi

	# DEBUG only: echo "$IAMRESP" | tail -n1 | jq -C .

	#if test -n "$DEBUG"; then
	#	echo "$IAMRESP" | sed 's/X-Subject-Token: MII.*$/X-Subject-Token: MIIsecretsecret/' 1>&2
	#fi
	if test -z "$KEYSTONE_URL"; then KEYSTONE_URL=$BASEURL/v3; fi
	if test -z "$CEILOMETER_URL"; then CEILOMETER_URL=${BASEURL/iam/ces}; fi

	AUTH_URL_ECS="$NOVA_URL/servers"
	export AUTH_URL_ECS_JOB="${NOVA_URL/v2/v1}/jobs"
	export AUTH_URL_ECS_DETAIL="$NOVA_URL/servers/detail"

	AUTH_URL_ECS_CLOUD="${NOVA_URL/v2/v1}/cloudservers"
	AUTH_URL_ECS_CLOUD_ACTION="$AUTH_URL_ECS_CLOUD/action"
	AUTH_URL_ECS_CLOUD_DELETE="$AUTH_URL_ECS_CLOUD/delete"
	AUTH_URL_FLAVORS="$AUTH_URL_ECS_CLOUD/flavors"
	AUTH_URL_KEYNAMES="$NOVA_URL/os-keypairs"

	AUTH_URL_VPCS="$NEUTRON_URL/v1/$OS_PROJECT_ID/vpcs"
	AUTH_URL_PUBLICIPS="$NEUTRON_URL/v1/$OS_PROJECT_ID/publicips"
	AUTH_URL_SEC_GROUPS="$NEUTRON_URL/v1/$OS_PROJECT_ID/security-groups"
	AUTH_URL_SEC_GROUP_RULES="$NEUTRON_URL/v2/$OS_PROJECT_ID/security-group-rules"
	AUTH_URL_SUBNETS="$NEUTRON_URL/v1/$OS_PROJECT_ID/subnets"

	AUTH_URL_IMAGES="$GLANCE_URL/v2/images"
	AUTH_URL_IMAGESV1="$GLANCE_URL/v1/cloudimages"
	AUTH_URL_IMAGESV2="$GLANCE_URL/v2/cloudimages"

	VBS_URL="${CINDER_URL/evs/vbs}"
	AUTH_URL_CVOLUMES="$CINDER_URL/cloudvolumes"
	AUTH_URL_CVOLUMES_DETAILS="$CINDER_URL/cloudvolumes/detail"
	AUTH_URL_VOLS="$CINDER_URL/volumes"
	AUTH_URL_CBACKUPS="$VBS_URL/cloudbackups"
	AUTH_URL_CBACKUPPOLS="$VBS_URL/backuppolicy"
	AUTH_URL_BACKS="$CINDER_URL/backups"
	AUTH_URL_SNAPS="$CINDER_URL/snapshots"

	AUTH_URL_ELB="${NEUTRON_URL/vpc/elb}/v1.0/$OS_PROJECT_ID/elbaas"
	AUTH_URL_ELB_LB="$AUTH_URL_ELB/loadbalancers"

	if test -z "$TROVE_URL"; then TROVE_URL=${BASEURL/iam/rds}; TROVE_OVERRIDE=1; fi
	AUTH_URL_RDS="$TROVE_URL/rds"
	AUTH_URL_RDS_DOMAIN="${AUTH_URL_RDS}/v1/$OS_USER_DOMAIN_ID"
	AUTH_URL_RDS_PROJECT="${AUTH_URL_RDS}/v1/$OS_PROJECT_ID"

	AUTH_URL_DNS="$DESIGNATE_URL/v2/zones"

	AUTH_URL_AS="${HEAT_URL/rts/as}"
	AUTH_URL_AS="${AUTH_URL_AS%%/v[12]*}"

	AUTH_URL_CES="$CEILOMETER_URL"
	AUTH_URL_CCE="${BASEURL/iam/cce}"

	AUTH_URL_KMS="${BASEURL/iam/kms}"
	AUTH_URL_SMN="${BASEURL/iam/smn}"
	AUTH_URL_CTS="${BASEURL/iam/cts}"
	AUTH_URL_DMS="${BASEURL/iam/dms}"
}

build_data_volumes_json() {
   info_str=$1

   DATA_VOLUMES=""
   disks=(${info_str//,/ })
   for disk in "${disks[@]}"
   do
      info=(${disk//:/ })
      if test -n "$DATA_VOLUMES"; then
         DATA_VOLUMES="$DATA_VOLUMES,";
      fi
      DATA_VOLUMES="$DATA_VOLUMES{\"volumetype\":\"${info[0]}\",\"size\":${info[1]}}"
   done
   echo $DATA_VOLUMES
}

# Usage
printHelp() {
	echo "otc-tools version $VERSION: OTC API tool"
	echo "Usage: otc.sh service action [options]"
	echo "--- Elastic Cloud Server (VM management) ---"
	echo "otc ecs list               # list ecs instances"
	echo "    --limit NNN            # limit records (works for most list functions)"
	echo "    --marker ID            # start with record after marker (UUID) (dito)"
	echo "    --maxgetkb NN          # auto-paginate (limiting responses to NN KiB max, def 250)"
	echo "otc ecs list-detail [ECS]  # list ecs instances in full detail (JSON)"
	echo "otc ecs details [ECS]      # list ecs instances in some detail (table)"
	echo "otc ecs show <vmid>        # show instance <vmid>"
	echo "otc ecs create -n <name>   # create ecs instance <name>"
	echo
	echo "otc ecs create             # create vm example"
	echo "    --count 1              # one instance (default)"
	echo "    --public true          # with public ip"
	echo "    --file1 /tmp/a=/otc/a  # attach local file /tmp/a to /otc/a in VM"
	echo "    --file2 ...            # Up to 5 files can be injected this way"
	echo
	echo "otc ecs create             # create vm (addtl. options)"
	echo "    --instance-type       <FLAVOR>"
	echo "    --instance-name       <NAME>"
	echo "    --image-name          <IMAGE>"
	echo "    --subnet-name         <SUBNET>"
	echo "    --fixed-ip            <IP>"
	echo "    --vpc-name            <VPC>"
	echo "    --security-group-name <SGNAME>"
	echo "    --security-group-ids  <SGID>,<SGID>,<SGID>"
	echo "    --admin-pass          <PASSWD>"
	echo "    --key-name            <SSHKEYNAME>"
	echo "    --user-data           <USERDYAMLSTRG> # don't forget #cloud-config header"
	echo "    --user-data-file      <USERDFILEG>    # don't forget #cloud-config header"
	echo "    --public              <true/false/IP>"
	echo "    --volumes             <device:volume>[<device,volume>[,..]]    # attach volumes as named devices"
	echo "    --bandwidth           <BW>		# defaults to 25"
	echo "    --bandwidth-name      <BW-NAME>	# defaults to bandwidth-BW"
	echo "    --disksize            <DISKGB>"
	echo "    --disktype            SATA|SAS|SSD	# SATA is default"
   echo "    --datadisks           <DATADISK> # format: <TYPE:SIZE>[,<TYPE:SIZE>[,...]]"
   echo "                                       example: SSD:20,SATA:50"
	echo "    --az                  <AZ>		# determined from subnet by default"
	echo "    --[no]wait"
	echo
	echo "otc ecs reboot-instances <id>   # reboot ecs instance <id>"
	echo "                                # optionally --soft/--hard"
	echo "otc ecs stop-instances <id>     # stop ecs instance <id>, dito"
	echo "otc ecs start-instances <id>    # start ecs instance <id>"
	echo "otc ecs delete                  # delete VM"
	#echo "    --umount <dev:vol>[,..]     # umount named volumes before deleting the vm" ##### current issue
	echo "    --[no]wait                  # wait for completion (default: no)"
	echo "    --keepEIP                   # default: delete EIP too"
	echo "    --delVolume                 # default: delete only system volume, not any volume attached"
	echo "    <ecs> <ecs> ...             # you could give IDs or names"
	echo "otc ecs job <id>                # show status of job <id>"
	echo "otc ecs limits                  # display project quotas"
	echo "otc ecs update <id>             # change VM data (same parms as create)"
	echo "otc ecs az-list                 # list availability zones"
	echo "otc ecs flavor-list             # list available flavors"
	echo
	echo "--- Task/Job management ---"
	echo "otc task show <id>              # show status of job <id> (same as ecs job)"
	echo "otc task delete <id>            # cancel job <id> (not yet supported)"
	echo "otc task wait <id> [sec]        # wait for job <id>, poll every sec sec (def: 2)"
	echo
	echo "--- SSH Keys ---"
	echo "otc keypair list                # list ssh key pairs"
	echo "otc keypair show <KPNAME>       # show ssh key pair"
	echo "otc keypair create <NAME> [<PUBKEY>]      # create ssh key pair"
	echo "otc keypair delete <KPNAME>     # delete ssh key pair"
	echo
	echo "--- Elastic Volume Service (EVS) ---"
	echo "otc evs list                    # list all volumes (only id and name)"
	echo "otc evs details                 # list all volumes (more details)"
	echo "otc evs show <id>               # show details of volume <id>"
	echo "otc evs create                  # create a volume"
	echo "    --volume-name         <NAME>"
	echo "    --disksize            <DISKGB>"
	echo "    --disktype            SATA|SAS|SSD	# SATA is default"
	echo "    --az                  <AZ>"
	echo "otc evs delete                  # delete volume"
	echo
	echo "otc evs attach        ecsid    device:volumeid    # attach volume at ecs using given device name"
	echo "otc evs attach --name ecsname  device:volume      # use names instead of ids"
	echo "otc evs detach        ecsid   [device:]volumeid   # detach volume-id from ecs"
	echo "otc evs detach --name ecsname [device:]volume     # use names instead of ids"
	#TODO volume change ...
	echo "--- Elastic Volume Backups ---"
	echo "otc backup list"
	echo "otc backup show backupid"
	echo "otc backup create --name NAME volumeid # Create backup from volume"
	echo "otc backup restore backupid volumeid   # restore backup to volume"
	echo "otc backup delete backupid"
	echo "otc snapshot list                      # list snapshots"
	echo "otc snapshot show snapid               # details of snapshot snapid"
	echo "otc snapshot delete snapid             # delete snapshot snapid"
	echo "otc backuppolicy list                  # list backup policies"
	echo "otc backuppolicy show NAME|ID          # details of backup policy"
	echo
	echo "--- Virtual Private Network (VPC) ---"
	echo "otc vpc list                    # list all vpc"
	echo "otc vpc show VPCID              # display VPC (Router) details"
	echo "otc vpc delete VPCID            # delete VPC"
	echo "otc vpc create                  # create vpc"
	echo "    --vpc-name <vpcname>"
	echo "    --cidr     <cidr>"
	echo
	echo "otc subnet list                 # list all subnet"
	echo "otc subnet show <SID>           # show details for subnet <SID>"
	echo "otc subnet delete <SID>         # delete subnet <SID>"
	echo "    --vpc-name          <vpcname>"
	echo "otc subnet create               # create a subnet"
	echo "    --subnet-name       <subnetname>"
	echo "    --cidr              <cidr>"
	echo "    --gateway-ip        <gateway>"
	echo "    --primary-dns       <primary-dns>"
	echo "    --secondary-dns     <sec-dns>"
	echo "    --availability-zone <avalibility zone>"
	echo "    --vpc-name          <vpcname>"
	echo
	echo "otc publicip list               # list all publicips"
	echo
	echo "otc publicip create             # create a publicip"
	echo "    --bandwidth-name    <bandwidthame>"
	echo "    --bandwidth         <bandwidth>"
	echo
	echo "otc publicip delete <id>        # delete a publicip (EIP)"
	echo "otc publicip bind <publicip-id> <port-id> # bind a publicip to a port"
	echo "otc publicip unbind <publicip-id>         # unbind a publicip"
	echo
	echo "otc security-group list                   # list all sec. group"
	echo "otc security-group-rules list <group-id>  # list rules of sec. group <group-id>"
	echo
	echo "otc security-group create                 # create security group"
	echo "    -g <groupname>"
	echo "    --vpc-name <vpc name>"
	echo
	echo "otc security-group-rules create           # create sec. group rule"
	echo "    --security-group-name <secgroupname>"
	echo "    --direction           <direction>"
	echo "    --protocol            <protocol: tcp, udp, icmp>"
	echo "    --ethertype           <ethtype: IPv4,IPv6>"
	echo "    --portmin             <port range lower end>"
	echo "    --portmax             <port range upper end>"
	echo
	echo "--- Image Management Service (IMS) ---"
	echo "otc images list [FILTERS]       # list all images (optionally use prop filters)"
	echo "otc images show <id>    # show image details"
	echo "otc images upload <id> filename           # upload image file (OTC-1.1+)"
	echo "otc images upload <id> bucket:objname     # specify image upload src (via s3)"
	echo "otc images download <id> bucket:objname   # export priv image into s3 object"
	echo "otc images create NAME          # create (private) image with name"
	echo "    --disk-format  <disk-format>"
	echo "    --min-disk     <GB>"
	echo "    --min-ram      <MB>         # optional (default 1024)"
	echo "    --os-version   <os_version> # optional (default Other)"
	echo "    --property     <key=val>    # optional properties (multiple times possible)"
	echo "otc images create NAME          # create image from ECS instance (snapshot)"
	echo "    --image-name   <image name>"
	echo "    --instance-id  <instance id>"
	echo "    --description  <description># optional"
	echo "otc images register NAME FILE   # create (private) image with name and s3 file"
	echo "    --property, --min-disk, --os-version and --wait supported"
	echo "otc images update <id>          # change properties, --image-name, min-*"
	echo "otc images delete <id>          # delete (private) image by ID"
	echo
	echo "otc images listshare <id>       # list projects image id is shared with"
	echo "otc images showshare <id> <prj> # show detailed image sharing status"
	echo "otc images share <id> <prj>     # share image id with prj"
	echo "otc images unshare <id> <prj>   # stop sharing img id with prj"
	echo "otc images acceptshare <id> [<prj>]       # accept image id shared into prj (default to self)"
	echo "otc images rejectshare <id> [<prj>]       # reject image id shared into prj"
	echo
	echo "--- Elastic Load Balancer (ELB) ---"
	echo "otc elb list            # list all load balancer"
	echo "otc elb show <id>       # show elb details"
	echo "otc elb create [<vpcid> [<name> [<bandwidth>]]]   # create new elb"
	echo "    --vpc-name <vpcname>"
	echo "    --bandwidth <bandwidth>               # in Mbps"
	echo "    --subnet-name/id <subnet>             # creates internal ELB listening on subnet"
	echo "    --security-group-name/id <secgroup>   # for internal ELBs"
	echo "otc elb delete <eid>            # Delete ELB with <eid>"

	echo "otc elb listlistener <eid>      # list listeners of load balancer <eid>"
	echo "otc elb showlistener <lid>      # show listener detail <lid>"
	echo "otc elb addlistener <eid> <name> <proto> <port> [<alg> [<beproto> [<beport>]]]"
	#not implemented: modifylistener
	echo "otc elb dellistener <lid>"
	echo "otc elb listmember <lid>"
	echo "otc elb showmember <lid> <mid>"
	echo "otc elb addmember <lid> <vmid> <vmip>"
	echo "otc elb delmember <lid> <mid> <vmip>"
	#elb listcheck <lid> is missing (!)
	echo "otc elb showcheck <cid>"
	echo "otc elb addcheck <lid> <proto> <port> <int> <to> <hthres> <uthres> [<uri>]"
	echo "otc elb delcheck <cid>"
	echo
	echo "--- Relational Database Service (RDS) ---"
	echo "otc rds list"
	echo "otc rds listinstances                                # list database instances"
	echo "otc rds show [<id> ...]"
	echo "otc rds showinstances  [<id> ...]                    # show database instances details"
	echo "otc rds apis"
	echo "otc rds listapis                                     # list API ids"
	echo "otc rds showapi <id> ...                             # show API detail information"
	echo "otc rds showdatastore MySQL|PostgreSQL ...           # show datastore ids and metadata"
	echo "otc rds datastore ...                                # alias for 'showdatastore'"
	echo "otc rds showdatastoreparameters <datastore_id> ...   # show all configuration parameters"
	echo "otc rds showdatastoreparameter <datastore_id> <name> # show a configuration parameter"
	echo "otc rds listflavors <datastore_id>"
	echo "otc rds flavors <datastore_id>                       # list RDS flavors"
	echo "otc rds showflavor <id> ...                          # RDS flavor details"
	echo "otc rds create [<configfile>]                        # create RDS instance, read from"
	echo "                                                     # stdin when no config file is given"
	echo "otc rds delete <id> <backups>                        # remove RDS instances and backups"
	echo "otc rds showbackuppolicy <id> ...                    # show backup policy of database <id>"
	echo "otc rds listsnapshots                                # list all backups"
	echo "otc rds listbackups                                  # alias for 'listsnapshots'"
	echo "otc rds showerrors <id> <startDate> <endDate>        # shows db instance errors currently"
	echo "                        <page> <entries>             # limited to last month and MySQL"
	echo "otc rds showslowstatements                           # shows db instance errors currently"
	echo "                        <id>                         # id of db instance"
	echo "                        select|insert|update|delete  # one of the statement type"
	echo "                        <entries>                    # top longest stmts to show (1-50)"
	echo "otc rds showslowqueries ...                          # alias for 'showslowstatements'"
	echo "otc rds createsnapshot <id> <name> <description>     # create a snapshot from an instance"
	echo "otc rds createbackup ...                             # alias for 'createsnapshot'"
	echo "otc rds deletesnapshot <id>                          # deletes a snapshot of an instance"
	echo "otc rds deletebackup ...                             # alias for 'deletesnapshot'"
	echo
	echo "--- DNS ---"
	echo "otc domain list         # show all zones/domains"
	echo "otc domain show zid     # show details of zone/domain <zid>"
	echo "otc domain delete zid   # deleted zone/domain <zid>"
	echo "otc domain create domain [desc [type [mail [ttl]]]]"
	echo "                        # create zone for domain (name. or ...in-addr.arpa.)"
	echo "                        # desc, public/private, mail, ttl (def: 300s) optional"
	echo "otc domain addrecord	zid name. type ttl val [desc]"
	echo "                        # add record to zone <zid> for <name> with <type>, <ttl>"
	echo "                        # type could be A, AAAA, MX, CNAME, PTR, TXT, NS"
	echo "                        # val is a comma sep list of record values, e.g."
	echo "                        # IPADDR, NR NAME, NAME, NAME, STRING, NAME."
	echo "otc domain showrecord zid rid     # show record <rid> for zone <zid>"
	echo "otc domain listrecords [zid]      # list records for zone <zid>"
	echo "otc domain delrecord zid rid      # delete record <rid> in zone <zid>"
	echo
	echo "--- Cloud Container Engine (CCE) ---"
	echo "otc cluster list                  # list container clusters (short)"
	echo "otc cluster list-detail           # list container clusters (detailed)"
	echo "otc cluster show <cid>            # show container cluster details of cid"
	echo "otc host list <cid>               # list container hosts of cluster cid"
	echo "otc host show <cid> <hid>         # show host hid details (cluster cid)"
	echo
	echo "--- Access Control (IAM) ---"
	echo "otc iam token           # generate a new iam token"
	echo "    --domainscope       # generate a domain scoped token (can be used globally)"
	echo "otc iam catalog         # catalog as returned with token"
	echo "otc iam project         # output project_id/tenant_id"
	echo "otc iam services        # service catalog"
	echo "otc iam endpoints       # endpoints of the services"
	echo "otc iam users           # get user list"
	echo "otc iam groups          # get group list"
	echo "--- Access Control: Federation ---"
	echo "otc iam listidp         # list Identity Providers"
	echo "otc iam showidp IDP     # details of IDP"
	echo "otc iam listmapping     # list mappings"
	echo "otc iam showmapping IDP # details of mapping IDP"
	echo "otc iam listprotocol    # list of federation protocols"
	echo "otc iam showprotocol PR # show details of federation protocal"
	echo "otc iam keystonemeta    # show keystone metadata"
	echo
	echo "--- Monitoring & Alarms (Cloud Eye) ---"
	echo "otc metrics list [NS [MET [SELECTORS]]]  # display list of avail metrics"
	echo "otc metrics favorites                    # display list of favorite metrics"
	echo "otc metrics show NS MET FROM TO PER AGR [SELECTORS]	# get metrics"
	echo "      NS = namespace (e.g. SYS.ECS), MET = metric_name (e.g. cpu_util)"
	echo "      FROM and TO  are timestamps in s since 1970, use NOW-3600 for 1h ago"
	echo "      PER = 1, 300, 1200, 3600, 14400, 86400  period b/w data points in s"
	echo "      AGR = min, max, average, variance  to specify aggregation mode"
	echo "      SELECTORS  define which data is used with up to three key=value pairs"
	echo "        e.g. instance_id=00826ea4-aa15-4725-9fa7-8ea10f765a3f"
	echo "      Note that timestamps in response are in s since 1970 (UTC)"
	echo "      API docu calls SELECTORS dimensions and aggregation mode filter"
	echo "      Example: otc metrics list \"\" \"\" instance_id=\$VMUUID"
	echo "otc alarms list         # list configured alarms"
	echo "otc alarms limits       # display alarm quotas"
	echo "otc alarms show ALID    # display details of alarm ALID"
	echo "otc alarms delete ALID  # delete alarm ALID"
	echo "otc alarms en/disable ALID        # enable/disable ALID"
	echo
	echo "--- OTC2.0 new services ---"
	echo "otc trace list          # List trackers from cloud trace"
	echo "otc queues list         # List queues from distr message system"
	echo "otc notifications list  # List notification topics from messaging service"
	echo
	echo "--- Custom command support ---"
	echo "otc custom [--jqfilter FILT] METHOD URL [JSON]        # Send custom command"
	echo "      METHOD=GET/PUT/POST/DELETE, vars with \\\$ are evaluated (not sanitized!)"
   echo "      example: otc custom GET \\\$BASEURL/v2/\\\$OS_PROJECT_ID/servers"
	echo "      note that \\\$BASEURL gets prepended if URL starts with /"
	echo "    --jqfilter allows to use a filtering string for jq processing (def=.)"
   echo "      e.g.: --jqfilter '.servers[] | .id+\\\"   \\\"+.name' GET \\\$NOVA_URL/servers"
	echo
	echo "--- Metadata helper ---"
	echo "otc mds meta_data [FILT]          # Retrieve and output meta_data"
	echo "otc mds vendor_data [FILT]        # Retrieve and output vendor_data"
	echo "      FILT is an optional jq string to process the data"
	echo "otc mds user_data                 # Retrieve and output user_data"
	echo "otc mds password                  # Retrieve and output password (unused)"
	echo
	echo "--- Global flags ---"
	echo "otc debug CMD1 CMD2 PARAMS        # for debugging REST calls ..."
	echo "otc --insecure CMD1 CMD2 PARAMS   # for ignoring SSL security ..."
}


# Functions

# Check if $1 is in uuid format
is_uuid()
{
	echo "$1" | grep '^[0-9a-f]\{8\}\-[0-9a-f]\{4\}\-[0-9a-f]\{4\}\-[0-9a-f]\{4\}\-[0-9a-f]\{12\}$' >/dev/null 2>&1
}

getid() {
	head -n1 | cut -d':' -f2 | tr -d '" ,'
}

# Store params used to do auto-pagination
# $1 => approx record size
# $2 => header size
# $3 => array name
# $4 => name od marker (default: id)
setapilimit()
{
	RECSZ=$1
	HDRSZ=$2
	ARRNM=$3
	IDFIELD=${4:-id}
}

PARAMSTRING=""
setlimit()
{
	if [ -z "$APILIMIT" -a -n "$1" ]; then
		export PARAMSTRING="?limit=$1"
	elif [ "$APILIMIT" == "off" -o -z "$1" ]; then
		export PARAMSTRING=""
	elif ( echo $APILIMIT | grep -q "^[0-9]*$" ); then
		export PARAMSTRING="?limit=$APILIMIT"
	else
		echo "APILIMIT set to $APILIMIT which is neither off not an integer." 1>&2
		exit 1
	fi

	if  ( echo $APIOFFSET | grep -q "^[0-9]\+$" ); then
		if [ -z "PARAMSTRING" ]; then
			export PARAMSTRING="?start=$APIOFFSET"
		else
			export PARAMSTRING="$PARAMSTRING&start=$APIOFFSET"
		fi
	fi

	if [ -n "$APIMARKER" ]; then
		if [ -z "PARAMSTRING" ]; then
			export PARAMSTRING="?marker=$APIMARKER"
		else
			export PARAMSTRING="$PARAMSTRING&marker=$APIMARKER"
		fi
	fi

	while [ -n "$2" ]; do
		echo $2
		if [ -z "PARAMSTRING" ]; then
			export PARAMSTRING="?$2"
		else
			export PARAMSTRING="$PARAMSTRING&$2"
		fi
		shift
	done
}

# Params: ARRNM Value [attr [id]]
find_id()
{
	ANM=${3:-name}
	IDN=${4:-id}
	jq '.'$1'[] | select(.'$ANM' == "'$2'") | .'$IDN | tr -d '", '
}

# Params: ARRNM Value addattr [match [attr [id]]]
find_id_ext()
{
	ANM=${5:-name}
	IDN=${6:-id}
	if test -n "$4"; then FILT=" and .$3 == \"$4\""; fi
	#echo jq ".$1[] | select(.$ANM == \"$2\"$FILT) | .$IDN" 1>&2
	jq ".$1[] | select(.$ANM == \"$2\"$FILT) | .$IDN" | tr -d '", '
}

# Flatten array
arraytostr()
{
	sed -e 's@\["\([^"]*\)",@\1,@g' -e 's@,"\([^"]*\)",@ \1,@g' -e 's@\(,\| \[\)"\([^"]*\)"\]@ \2@g'
}

# convert functions
# $1: name
# $2: VPCID (optional)
convertSUBNETNameToId() {
	#curlgetauth $TOKEN "$AUTH_URL_SUBNETS?limit=800"
	#SUBNETID=`curlgetauth $TOKEN "$AUTH_URL_SUBNETS" | jq '.subnets[] | select(.name == "'$1'") | .id' | tr -d '" ,'`
	#setlimit 800
	setlimit; setapilimit 360 20 subnets
	SUBNETS=`curlgetauth_pag $TOKEN "$AUTH_URL_SUBNETS$PARAMSTRING"`
	SUBNETID=`echo "$SUBNETS" | find_id_ext subnets "$1" "vpc_id" "$2"`
	SUBNETAZ=`echo "$SUBNETS" | find_id_ext subnets "$1" "vpc_id" "$2" name availability_zone`
	if test -z "$SUBNETID"; then
		echo "ERROR: No subnet found by name $1" 1>&2
		exit 3
	fi
	export SUBNETID SUBNETAZ
}

convertVPCNameToId() {
	#curlgetauth $TOKEN "$AUTH_URL_VPCS?limit=500"
	#VPCID=`curlgetauth $TOKEN "$AUTH_URL_VPCS?limit=500" | jq '.vpcs[] | select(.name == "'$1'") | .id' | tr -d '" ,'`
	#setlimit 500
	setlimit; setapilimit 320 20 vpcs
	VPCID=`curlgetauth_pag $TOKEN "$AUTH_URL_VPCS$PARAMSTRING" | find_id vpcs "$1"`
	if test -z "$VPCID"; then
		echo "ERROR: No VPC found by name $1" 1>&2
		exit 3
	fi
	#echo $VPCID
	export VPCID
}

convertSECUGROUPNameToId() {
	unset IFS
	#SECUGROUP=`curlgetauth $TOKEN "$AUTH_URL_SEC_GROUPS" | jq '.security_groups[] | select(.name == "'$1'") | .id' | tr -d '" ,'`
	#SECUGROUP=`curlgetauth $TOKEN "$AUTH_URL_SEC_GROUPS" | find_id security_groups "$1"`
	#setlimit 500
	setlimit; setapilimit 4000 40 security_groups
	SECUGROUP=`curlgetauth_pag $TOKEN "$AUTH_URL_SEC_GROUPS$PARAMSTRING" | jq '.security_groups[] | select(.name == "'"$1"'") | .id' | tr -d '" ,'`
	if test `echo "$SECUGROUP" | wc -w` -gt 1; then
		SECUGROUP=`curlgetauth_pag $TOKEN "$AUTH_URL_SEC_GROUPS$PARAMSTRING" | jq '.security_groups[] | select(.name == "'"$1"'") | select(.vpc_id == "'"$VPCID"'") | .id' | tr -d '" ,'`
	fi
	if test -z "$SECUGROUP"; then
		echo "ERROR: No security-group found by name $1" 1>&2
		exit 3
	fi
	if test `echo "$SECUGROUP" | wc -w` != 1; then
		echo "Warn: Non-unique Security Group mapping: $1 -> $SECUGROUP" 1>&2
		SECUGROUP=`echo "$SECUGROUP" | head -n 1`
	fi
	export SECUGROUP
}

convertIMAGENameToId() {
	#IMAGE_ID=`curlgetauth $TOKEN "$AUTH_URL_IMAGES" | jq '.images[] | select(.name == "'$IMAGENAME'") | .id' | tr -d '" ,'`
	#setlimit 800
	setlimit; setapilimit 1600 100 images
	IMAGE_ID=`curlgetauth_pag $TOKEN "$AUTH_URL_IMAGES$PARAMSTRING" | find_id images "$1"`
	if test -z "$IMAGE_ID"; then
		echo "ERROR: No image found by name $1" 1>&2
		exit 3
	fi
	if test "$(echo "$IMAGE_ID" | wc -w)" != "1"; then
		IMAGE_ID=$(echo "$IMAGE_ID" | head -n1)
		echo "Warn: Multiple images found by that name; using $IMAGE_ID" 1>&2
	fi
	export IMAGE_ID
}

convertECSNameToId() {
	#setlimit 1600
	setlimit; setapilimit 420 40 servers id
	ECS_ID=`curlgetauth_pag $TOKEN "$AUTH_URL_ECS$PARAMSTRING" | jq '.servers[] | select(.name == "'$1'") | .id' | tr -d '" ,'`
	if test -z "$ECS_ID"; then
		echo "ERROR: No VM found by name $1" 1>&2
		exit 3
	fi
	if test "$(echo "$ECS_ID" | wc -w)" != "1"; then
		ECS_ID=$(echo "$ECS_ID" | head -n1)
		echo "Warn: Multiple VMs found by that name; using $ECS_ID" 1>&2
	fi
	export ECS_ID
}

convertEVSNameToId() {
	#setlimit 1600
	setlimit; setapilimit 400 30 volumes
	EVS_ID=`curlgetauth_pag $TOKEN "$AUTH_URL_VOLS$PARAMSTRING" | jq '.volumes[] | select(.name == "'$1'") | .id' | tr -d '" ,'`
	if test -z "$EVS_ID"; then
		echo "ERROR: No volume found by name $1" 1>&2
		exit 3
	fi
	if test "$(echo "$EVS_ID" | wc -w)" != "1"; then
		EVS_ID=$(echo "$EVS_ID" | head -n1)
		echo "Warn: Multiple volumes found by that name; using $EVS_ID" 1>&2
	fi
	export EVS_ID
}

convertBackupNameToId() {
	#setlimit 1600
	setlimit; setapilimit 1280 30 backups
	BACK_ID=`curlgetauth_pag $TOKEN "$AUTH_URL_BACKS$PARAMSTRING" | jq '.backups[] | select(.name == "'$1'") | .id' | tr -d '" ,'`
	if test -z "$BACK_ID"; then
		echo "ERROR: No backup found by name $1" 1>&2
		exit 3
	fi
	if test "$(echo "$BACK_ID" | wc -w)" != "1"; then
		BACK_ID=$(echo "$BACK_ID" | head -n1)
		echo "Warn: Multiple backups found by that name; using $BACK_ID" 1>&2
	fi
	export BACK_ID
}

convertBackupPolicyNameToId() {
	#setlimit 800
	setlimit; setapilimit 320 40 backup_policies
	BACKPOL_ID=`curlgetauth_pag $TOKEN "$AUTH_URL_CBACKUPPOLS$PARAMSTRING" | jq '.backup_policies[] | select(.name == "'$1'") | .id' | tr -d '" ,'`
	if test -z "$BACKPOL_ID"; then
		echo "ERROR: No backup policy found by name $1" 1>&2
		exit 3
	fi
	if test "$(echo "$BACKPOL_ID" | wc -w)" != "1"; then
		BACKPOL_ID=$(echo "$BACKPOL_ID" | head -n1)
		echo "Warn: Multiple backups found by that name; using $BACKPOL_ID" 1>&2
	fi
	export BACKPOL_ID
}

convertSnapshotNameToId() {
	#setlimit 1600
	setlimit; setapilimit 440 30 snapshots
	SNAP_ID=`curlgetauth_pag $TOKEN "$AUTH_URL_SNAPS$PARAMSTRING" | jq '.snapshots[] | select(.name == "'$1'") | .id' | tr -d '" ,'`
	if test -z "$SNAP_ID"; then
		echo "ERROR: No snapshot found by name $1" 1>&2
		exit 3
	fi
	if test "$(echo "$SNAP_ID" | wc -w)" != "1"; then
		SNAP_ID=$(echo "$SNAP_ID" | head -n1)
		echo "Warn: Multiple snapshots found by that name; using $SNAP_ID" 1>&2
	fi
	export SNAP_ID
}

handleCustom()
{
	if test "$1" == "--jqfilter"; then JQFILTER="$2"; shift; shift; else JQFILTER="."; fi
	if test -n "$JQFILTER"; then JQ="jq -r \"$JQFILTER\""; else JQ="cat -"; fi
	METH=$1
	# NOTE: We better TRUST the caller not to pass in malicious things here
	#  so never call otc custom from a script that accepts non-sanitized args
	# TODO: Replace the knowledge of internal shell vars by a documented set
	#  the user can use here and do sed to fill in rather than eval.
	URL=$(eval echo "$2")
	if test "${URL:0:1}" == "/"; then URL="$BASEURL$URL"; fi
	shift; shift
	ARGS=$(eval echo "$@")
	echo "#DEBUG: curl -X $METH -d $ARGS $URL" 1>&2
	#TODO: Capture return code ...
	case "$METH" in
		GET)
			curlgetauth $TOKEN "$URL" | eval "$JQ"
			;;
		PUT)
			curlputauth $TOKEN "$ARGS" "$URL" | eval "$JQ"
			;;
		POST)
			curlpostauth $TOKEN "$ARGS" "$URL" | eval "$JQ"
			;;
		PATCH)
			curlpatchauth $TOKEN "$ARGS" "$URL" | eval "$JQ"
			;;
		DELETE)
			if test -z "$ARGS"; then
				curldeleteauth $TOKEN "$URL" | eval "$JQ"
			else
				curldeleteauthwithjsonparameter $TOKEN "$ARGS" "$URL" | eval "$JQ"
			fi
			;;
		*)
			echo "ERROR: Unknown http method $METH in otc custom" 1>&2
			exit 1
			;;
	esac
   if test -z "$JQFILTER"; then echo; fi
}


getECSVM() {
	if ! is_uuid "$1"; then convertECSNameToId "$1"; else ECS_ID="$1"; fi
	curlgetauth $TOKEN "$AUTH_URL_ECS/$ECS_ID" | jq -r '.[]'
	curlgetauth $TOKEN "$AUTH_URL_ECS/$ECS_ID/os-interface" | jq -r '.[]'
}

getShortECSList() {
	#curlgetauth $TOKEN "$AUTH_URL_ECS?limit=1600" | jq -r  '.servers[] | .id+"   "+.name'
	#setlimit 1600
	setlimit; setapilimit 420 40 servers id
	curlgetauth_pag $TOKEN "$AUTH_URL_ECS$PARAMSTRING" | jq -r  '.servers[] | .id+"   "+.name'
}

getECSList() {
	#curlgetauth $TOKEN "$AUTH_URL_ECS?limit=1200" | jq -r  '.servers[] | {id: .id, name: .name} | .id+"   "+.name'
	#setlimit 1200
	setlimit; setapilimit 2000 40 servers id
	curlgetauth_pag $TOKEN "$AUTH_URL_ECS_DETAIL$PARAMSTRING" | jq -r  'def adr(a): [a[]|.[]|{addr}]|[.[].addr]|tostring; .servers[] | {id: .id, name: .name, status: .status, flavor: .flavor.id, az: .["OS-EXT-AZ:availability_zone"], addr: .addresses} | .id+"   "+.name+"   "+.status+"   "+.flavor+"   "+.az+"   "+adr(.addr) ' | arraytostr
}

getECSDetails() {
	#setlimit 1200
	setlimit; setapilimit 2000 40 servers id
	if test -n "$1"; then
		if is_uuid "$1"; then
			curlgetauth_pag $TOKEN "$AUTH_URL_ECS_DETAIL$PARAMSTRING" | jq '.servers[] | select (.id == "'$1'")'
		else
			curlgetauth_pag $TOKEN "$AUTH_URL_ECS_DETAIL$PARAMSTRING" | jq '.servers[] | select (.name|test("'$1'"))'
		fi
	else
		curlgetauth_pag $TOKEN "$AUTH_URL_ECS_DETAIL$PARAMSTRING" | jq '.servers[]'
	fi
}

getECSDetail()
{
	getECSDetails "$1" | jq '{VM: .name, ID: .id, Detail: .}'
}

getECSDetailsNew() {
	RESP=$(getECSDetails "$1")
	echo "# VMID                                       name          status      AZ      SSHKeyName    Flavor      Image     Volumes   Nets   SGs"
	echo "$RESP" | jq -r  'def adr(a): [a[]|.[]|{addr}]|[.[].addr]|tostring; def vol(v): [v[]|{volid:.id}]|[.[].volid]|tostring; def sg(s): [s[]|{sgid:.name}]|[.[].sgid]|tostring; {id: .id, name: .name, status: .status, az: .["OS-EXT-AZ:availability_zone"], flavor: .flavor.id, sshkey: .key_name, addr: .addresses, image: .image.id, volume: .["os-extended-volumes:volumes_attached"], sg: .security_groups } | .id + "   " + .name + "   " + .status + "   " + .az + "   " + .sshkey + "   " + .flavor + "   " + .image + "   " + vol(.volume) + "   " + adr(.addr) + "   " + sg(.sg)' | arraytostr
	# TODO: Volume IDs into names, SG names
	# Add FloatingIP info
}

getLimits()
{
	curlgetauth $TOKEN "$AUTH_URL_ECS_CLOUD/limits" | jq '.'
}

getAZList() {
	curlgetauth $TOKEN "$NOVA_URL/os-availability-zone" | jq  '.availabilityZoneInfo[] | {znm: .zoneName, avl: .zoneState.available} | .znm' | tr -d '"'
}

getAZDetail() {
	curlgetauth $TOKEN "$NOVA_URL/os-availability-zone/$1" | jq  '.'
}


getVPCList() {
	#setlimit 500
	setlimit; setapilimit 320 20 vpcs
	curlgetauth_pag $TOKEN "$AUTH_URL_VPCS$PARAMSTRING" | jq -r '.vpcs[] | {id: .id, name: .name, status: .status, cidr: .cidr} | .id +"   " +.name    +"   " +.status   +"   " +.cidr  '
#| python -m json.tool
}

getVPCDetail() {
	if ! is_uuid "$1"; then convertVPCNameToId "$1"; else VPCID="$1"; fi
	curlgetauth $TOKEN "$AUTH_URL_VPCS/$VPCID" | jq -r '.'
}

VPCDelete() {
	if ! is_uuid "$1"; then convertVPCNameToId "$1"; else VPCID="$1"; fi
	curldeleteauth $TOKEN "$AUTH_URL_VPCS/$VPCID"
	echo
}

getPUBLICIPSList() {
	#curlgetauth $TOKEN "$AUTH_URL_PUBLICIPS?limit=500" | jq '.'
	#setlimit 500
	setlimit; setapilimit 400 30 publicips
	curlgetauth_pag $TOKEN "$AUTH_URL_PUBLICIPS$PARAMSTRING" | jq 'def str(v): v|tostring; .publicips[]  | .id +"   " +.public_ip_address +"   " +.status+"   " +.private_ip_address +"   " +str(.bandwidth_size) +"   " +.bandwidth_share_type ' | tr -d '"'
}

getPUBLICIPSDetail() {
	curlgetauth $TOKEN "$AUTH_URL_PUBLICIPS/$1" | jq '.'
}

getSECGROUPListDetail() {
	#setlimit 500
	setlimit; setapilimit 4000 40 security_groups
	curlgetauth_pag $TOKEN "$AUTH_URL_SEC_GROUPS$PARAMSTRING" | jq '.[]'
#| python -m json.tool
}

getSECGROUPList() {
	#setlimit 500
	setlimit; setapilimit 4000 40 security_groups
	curlgetauth_pag $TOKEN "$AUTH_URL_SEC_GROUPS$PARAMSTRING" | jq '.security_groups[] | {id: .id, name: .name, vpc: .vpc_id} | .id +"   " +.name+"   "+.vpc' | tr -d '"'
#| python -m json.tool
}

getSECGROUPRULESListOld() {
	curlgetauth $TOKEN "$AUTH_URL_SEC_GROUP_RULES" | jq '.[]'
#| python -m json.tool
}

getSECGROUPRULESList() {
	if ! is_uuid "$1"; then convertSECUGROUPNameToId "$1"; else SECUGROUP="$1"; fi
	#setlimit 800
	setlimit; setapilimit 4000 40 security_groups
	curlgetauth_pag $TOKEN "$AUTH_URL_SEC_GROUPS$PARAMSTRING" | jq '.security_groups[] | select(.id == "'$SECUGROUP'")'
#| python -m json.tool
}

getEVSListOTC() {
	#curlgetauth $TOKEN "$AUTH_URL_CVOLUMES?limit=1200" | jq '.volumes[] | {id: .id, name: .name} | .id +"   " +.name ' | tr -d '"'
	#setlimit 1200
	setlimit; setapilimit 2400 30 volumes
	curlgetauth_pag $TOKEN "$AUTH_URL_CVOLUMES/detail$PARAMSTRING" | jq 'def att(a): [a[0]|{id:.server_id, dev:.device}]|.[]|.id+":"+.dev; def str(v): v|tostring; .volumes[] | .id +"   " +.name+"   "+.status+"   "+.type+"   "+str(.size)+"   "+.availability_zone+"   "+att(.attachments) ' | tr -d '"'
}

getEVSList() {
	#setlimit 1600
	setlimit; setapilimit 400 30 volumes
	curlgetauth_pag $TOKEN "$AUTH_URL_VOLS$PARAMSTRING" | jq '.volumes[] | {id: .id, name: .name} | .id +"   " +.name ' | tr -d '"'
	#curlgetauth $TOKEN "$AUTH_URL_VOLS/details?limit=1200" | jq '.volumes[] | {id: .id, name: .name, status: .status, type: .volume_type, size: .size|tostring, az: .availability_zone} | .id +"   " +.name+"   "+.status+"   "+.type+"   "+.size+"   "+.az ' | tr -d '"'
}

getEVSDetail() {
	if ! is_uuid "$1"; then convertEVSNameToId "$1"; else EVS_ID="$1"; fi
	#curlgetauth $TOKEN "$AUTH_URL_CVOLUMES_DETAILS?limit=1200" | jq '.volumes[] | select(.id == "'$EVS_ID'")'
	curlgetauth $TOKEN "$AUTH_URL_VOLS/$EVS_ID" | jq '.volume'
}

getSnapshotList() {
	#setlimit 1200
	setlimit; setapilimit 440 30 snapshots
	curlgetauth_pag $TOKEN "$AUTH_URL_SNAPS$PARAMSTRING" | jq '.snapshots[] | {id: .id, name: .name, status: .status, upd: .updated_at} | .id +"   " +.name +"   "+.status+"   "+.upd ' | tr -d '"' | sed 's/\(T[0-9:]*\)\.[0-9]*$/\1/'
}

getSnapshotDetail() {
	if ! is_uuid "$1"; then convertSnapshotNameToId "$1"; else SNAP_ID="$1"; fi
	curlgetauth $TOKEN "$AUTH_URL_SNAPS/$SNAP_ID" | jq '.snapshot'
}

deleteSnapshot() {
	if ! is_uuid "$1"; then convertSnapshotNameToId "$1"; else SNAP_ID="$1"; fi
	curldeleteauth $TOKEN "$AUTH_URL_SNAPS/$SNAP_ID" | jq '.'
}

getBackupPolicyList() {
	#setlimit 800
	setlimit; setapilimit 320 40 backup_policies
	curlgetauth_pag $TOKEN "$AUTH_URL_CBACKUPPOLS$PARAMSTRING" | jq '.backup_policies[] | {id: .backup_policy_id, name: .backup_policy_name, status: .scheduled_policy.status} | .id+"   "+.name+"   "+.status' | tr -d '"'
}

getBackupPolicyDetail() {
	#setlimit 800
	setlimit; setapilimit 320 40 backup_policies
	if ! is_uuid "$1"; then filter=".name = \"$1\""; else filter=".id = \"$1\""; fi
	curlgetauth_pag $TOKEN "$AUTH_URL_CBACKUPPOLS$PARAMSTRING" | jq ".backup_policies[] | select($filter)"
}
# TODO: More backup policy stuff

getBackupList() {
	#curlgetauth $TOKEN "$AUTH_URL_BACKS?limit=1200" | jq '.backups[] | {id: .id, name: .name} | .id +"   " +.name ' | tr -d '"'
	#setlimit 1200
	setlimit; setapilimit 1280 30 backups
	curlgetauth_pag $TOKEN "$AUTH_URL_BACKS/detail$PARAMSTRING" | jq 'def str(v): v|tostring; .backups[] | .id +"   " +.name+"   "+.status+"   "+str(.size)+"   "+.availability_zone+"   "+.updated_at ' | tr -d '"' | sed 's/\(T[0-9:]*\)\.[0-9]*$/\1/'
}

getBackupDetail() {
	if ! is_uuid "$1"; then convertBackupNameToId "$1"; else BACK_ID="$1"; fi
	curlgetauth $TOKEN "$AUTH_URL_BACKS/$BACK_ID" | jq '.backup'
}

deleteBackupOTC() {
	if ! is_uuid "$1"; then convertBackupNameToId "$1"; else BACK_ID="$1"; fi
	#curldeleteauth $TOKEN "$AUTH_URL_CBACKUPS/$BACK_ID" | jq '.'
	BACKUP=$(curlpostauth $TOKEN "" "$AUTH_URL_CBACKUPS/$BACK_ID")
	TASKID=$(echo "$BACKUP" | jq '.job_id' | cut -d':' -f 2 | tr -d '" ')
        if test -z "$TASKID" -o "$TASKID" = "null"; then echo "ERROR: $BACKUP" 2>&1; exit 2; fi
        WaitForTask $TASKID
}

deleteBackup() {
	# TODO: Should we delete an associated snapshot as well that might have been
	# created via the cloudbackups OTC service API along with the backup?
	if ! is_uuid "$1"; then convertBackupNameToId "$1"; else BACK_ID="$1"; fi
	SNAP_ID=$(curlgetauth $TOKEN "$AUTH_URL_BACKS/$BACK_ID" | jq '.backup.container' | tr -d '"')
	if test -n "$SNAP_ID" -a "$SNAP_ID" != "null"; then
		SNAP_NAME=$(curlgetauth $TOKEN "$AUTH_URL_SNAPS/$SNAP_ID" | jq '.snapshot.name' | tr -d '"')
		if test -n "$SNAP_NAME" -a "$SNAP_NAME" != "null"; then
			if test "${SNAP_NAME:0:17}" = "autobk_snapshot_2"; then
				echo "Also deleting autogenerated container/snapshot $SNAP_ID ($SNAP_NAME)" 1>&2
				deleteSnapshot $SNAP_ID
			else
				echo "Not deleting container/snapshot $SNAP_ID ($SNAP_NAME), consider manual deletion" 1>&2
			fi
		fi
	fi
	curldeleteauth $TOKEN "$AUTH_URL_BACKS/$BACK_ID" | jq '.'
}

createBackup() {
	if test "$1" == "--name"; then NAME="$2"; shift; shift; fi
	if test -z "$1"; then echo "ERROR: Need to specify volumeid to be backed up" 1>&2; exit 2; fi
	if test -z "$NAME"; then NAME="Backup-$1"; fi
	REQ="{ \"backup\": { \"volume_id\": \"$1\", \"name\": \"$NAME\" } }"
	if test -n "$DESCRIPTION"; then REQ="${REQ%\} \}}, \"description\": \"$DESCRIPTION\" } }"; fi
	BACKUP=$(curlpostauth $TOKEN "$REQ" "$AUTH_URL_CBACKUPS")
	TASKID=$(echo "$BACKUP" | jq '.job_id' | cut -d':' -f 2 | tr -d '" ')
	if test -z "$TASKID" -o "$TASKID" = "null"; then echo "ERROR: $BACKUP" 2>&1; exit 2; fi
	echo "Not waiting for backup, use otc task show $TASKID to monitor (but wait for backup_id)"
	WaitForTaskFieldOpt $TASKID '.entities.backup_id'
}

restoreBackup() {
	if test -z "$2"; then echo "ERROR: Need to specify backupid and volumeid" 1>&2; exit 2; fi
	REQ="{ \"restore\": { \"volume_id\": \"$2\" } }"
	curlpostauth $TOKEN "$REQ" "$AUTH_URL_CBACKUPS/$1/restore" | jq '.'
	#echo
}

getSUBNETList() {
	#curlgetauth $TOKEN "$AUTH_URL_SUBNETS?limit=800" | jq '.[]'
	#setlimit 800
	setlimit; setapilimit 360 20 subnets
	curlgetauth_pag $TOKEN  "$AUTH_URL_SUBNETS$PARAMSTRING" | jq -r '.subnets[] | .id+"   "+.name+"   "+.status+"   "+.cidr+"   "+.vpc_id+"   "+.availability_zone' | tr -d '"'
}

getSUBNETDetail() {
	if ! is_uuid "$1"; then convertSUBNETNameToId "$1" "$VPCID"; else SUBNETID="$1"; fi
	curlgetauth $TOKEN "$AUTH_URL_SUBNETS/$SUBNETID" | jq '.[]'
}

SUBNETDelete() {
	if test -z "$VPCID"; then echo "ERROR: Need to specify --vpc-name/-id" 1>&2; exit 2; fi
	if ! is_uuid "$1"; then convertSUBNETNameToId "$1" "$VPCID"; else SUBNETID="$1"; fi
	curldeleteauth $TOKEN "$AUTH_URL_VPCS/$VPCID/subnets/$SUBNETID"
	echo
}

getRDSInstanceList() {
	#setlimit 500
	curlgetauth $TOKEN "${AUTH_URL_RDS_DOMAIN}/instances" | jq -r  '.instances[] | {id: .id, name: .name, type: .type} | .id + "   " + .name + " " + .type'
}

getRDSAllInstanceDetailsImpl() {
	#setlimit 500
	curlgetauth $TOKEN "${AUTH_URL_RDS_DOMAIN}/instances" | jq -r '.instances[]'
}

getRDSInstanceDetailsImpl() {
	local instanceid
	for instanceid in $*
	do
		local URI="${AUTH_URL_RDS_DOMAIN}/instances/${instanceid}"
		#echo "URI: $URI"
		curlgetauth $TOKEN "$URI" | jq -r '.instance'
	done
}

getRDSInstanceDetails() {
	[ $# -eq 0 ] && getRDSAllInstanceDetailsImpl
	[ $# -ne 0 ] && getRDSInstanceDetailsImpl "$@"
}

getRDSDatastoreDetails() {
	local datastore_name
	for datastore_name in $*
	do
		local URI="${AUTH_URL_RDS_DOMAIN}/datastores/${datastore_name}/versions"
		#echo "URI: $URI"
		curlgetauth $TOKEN "$URI" | jq -r '.dataStores[]'
	done
}

getRDSDatastoreParameters() {
	local datastore_version_id
	for datastore_version_id in $*
	do
		local URI="${AUTH_URL_RDS_PROJECT}/datastores/versions/${datastore_version_id}/parameters"
		#echo "URI: $URI"
		curlgetauth $TOKEN "$URI" | jq -r '.[]'
	done
}

getRDSDatastoreParameterImpl() {
	local datastore_version_id=$1
	local parameter_name=$2
	local URI="${AUTH_URL_RDS_PROJECT}/datastores/versions/${datastore_version_id}/parameters/${parameter_name}"
	#echo "URI: $URI"
	curlgetauth $TOKEN "$URI" | jq -r '.'
}

getRDSDatastoreParameter() {
	[ $# -eq 2 ] && getRDSDatastoreParameterImpl "$@"
	[ $# -eq 0 ] && echo "ERROR: Please specify the RDS datastore id and parameter name" 1>&2
}

getRDSAPIVersionList() {
	curlgetauth $TOKEN "${AUTH_URL_RDS}/" | \
		jq -r  '.versions[] | {id: .id, status: .status, updated: .updated} | .id+" "+.status+" "+.updated'
}

getRDSAPIDetails() {
	local api_id
	for api_id in $*
	do
		curlgetauth $TOKEN "${AUTH_URL_RDS}/${api_id}" | jq .versions[]
	done
}

getRDSFlavorList() {
	local dbid=$1;   shift
	local region=$1; shift
	[ -z "$region" ] && region=$OS_PROJECT_NAME # default to env
	local URI="${AUTH_URL_RDS_DOMAIN}/flavors?dbId=${dbid}&region=${region}"
	#echo "URI: $URI"
	curlgetauth $TOKEN "$URI" | jq -r '.'
	#\ jq -r  '.instances[] | {id: .id, name: .name, type: .type} | .id + "   " + .name + " " + .type'
}

getRDSFlavorDetails() {
	for flavorid in $*
	do
		local URI="${AUTH_URL_RDS_DOMAIN}/flavors/${flavorid}"
		#echo "URI: $URI"
		curlgetauth $TOKEN "$URI" | jq -r '.flavor'
	done
}

createRDSInstanceImpl() {
	# Parameter $* as descibed in
	# API Reference Issue 01 2016-06-30,
	# 4.7 Creating an Instance
	local URI="${AUTH_URL_RDS_DOMAIN}/instances"
	#echo "Parameter: $*"
	#echo "URI: $URI"
	curlpostauth $TOKEN "$*" "$URI" | jq '.'
}

createRDSInstance() {
	local rds_parameters="",zwerg;
	if [ $# -eq 0 ]; then
		# no parameter file given, read from stdin
		while read zwerg
		do
			rds_parameters.="$zwerg"
		done
	else
		rds_parameters=`cat $1`
	fi
	createRDSInstanceImpl "$rds_parameters"
}

deleteRDSInstanceImpl() {
	local instanceid=$1
	local numberOfManualBackupsToKeep=$2
	local URI="${AUTH_URL_RDS_DOMAIN}/instances/${instanceid}"
	#local URI="${AUTH_URL_RDS_PROJECT}/instances/${instanceid}"
	echo "Note: Try deleting instance $instanceid" 1>&2
	#echo "URI: $URI"
	#echo "TOKEN: $TOKEN"
	curldeleteauthwithjsonparameter \
		$TOKEN \
		"{ \"keepLastManualBackup\":\"${numberOfManualBackupsToKeep}\" }" \
		"$URI"
}

deleteRDSInstance() {
	[ $# -eq 2 ] && deleteRDSInstanceImpl "$@"
	[ $# -ne 2 ] && echo "ERROR: Please specify RDS instance id to delete and number of backups to keep" 1>&2
}

getRDSInstanceBackupPolicy() {
	local instanceid
	for instanceid in $*
	do
		local URI="${AUTH_URL_RDS_DOMAIN}/instances/${instanceid}/backups/policy"
		#echo "URI: $URI"
		curlgetauth $TOKEN "$URI" | jq -r '.[]'
	done
}

getRDSSnapshots() {
	local URI="${AUTH_URL_RDS_PROJECT}/backups"
	#echo "URI: $URI"
	curlgetauth $TOKEN "$URI" | jq -r '.'
}

printHelpQueryRDSErrorLogs() {
	echo 1>&2 "Parameters are: instanceId, startDate, endDate, page, entries"
	echo 1>&2 "Where:"
	echo 1>&2 "'instanceId' are the id of the database instance"
	echo 1>&2 "'startDate' and 'endDate' are of format like: 2016-08-29+06:35"
	echo 1>&2 "'page' is the page number, starting from 1"
	echo 1>&2 "'entries' the number of log lines per page, valid numbers are 1 to 100"
}

getRDSErrorLogsPrepareRequestParameters() {
	if [ $# -eq 5 ]; then
		local startDate=${2/:/%3A} # : => %3A
		local endDate=${3/:/%3A} # : => %3A
		echo "$1 $startDate $endDate $4 $5"
		return 0
	fi
	echo "ERROR: 5 parameters are expected" 1>&2
	printHelpQueryRDSErrorLogs
	echo ""
	return 1
}

getRDSErrorLogsImpl() {
	local instanceId=$1
	local startDate=$2
	local endDate=$3
	local curPage=$4
	local perPage=$5
	local URI="${AUTH_URL_RDS_PROJECT}/instances/${instanceId}/errorlog"
	URI+="?startDate=${startDate}"
	URI+="&endDate=${endDate}"
	URI+="&curPage=${curPage}"
	URI+="&perPage=${perPage}"
	#echo "URI: $URI"
	curlgetauth $TOKEN "$URI" | jq -r '.errorLogList[]| "\(.datetime) \(.content)"'
}

getRDSErrorLogs() {
	local parameters=$(getRDSErrorLogsPrepareRequestParameters $*)
	[ -n "$parameters" ] && getRDSErrorLogsImpl $parameters
}

getRDSSlowStatementLogsImpl() {
	local instanceId=$1
	local sftype=$(echo "$2" | tr '[:lower:]' '[:upper:]')
	local top=$3
	local URI="${AUTH_URL_RDS_PROJECT}/instances/${instanceId}/slowlog"
	URI+="?sftype=${sftype}"
	URI+="&top=${top}"
	#echo "URI: $URI"
	curlgetauth $TOKEN "$URI" | jq -r '.slowLogList[]'
}

getRDSSlowStatementLogs() {
	[ $# -eq 3 ] && getRDSSlowStatementLogsImpl "$@"
	[ $# -ne 3 ] && echo "ERROR: Please specify instance id, statement type and number of logs to show" 1>&2
}

createRDSSnapshotImpl() {
	local instanceId=$1
	local name=$2
	local description=$3
	local URI="${AUTH_URL_RDS_PROJECT}/backups"
	local REQ=""
	REQ+="{"
	REQ+='	"backup": {'
	REQ+='		"name":        "'${name}'",'
	REQ+='		"instance":    "'${instanceId}'",'
	REQ+='		"description": "'${description}'"'
	REQ+="	}"
	REQ+="}"
	#echo "URI: $URI"
	#echo "REQ: $REQ"
	curlpostauth $TOKEN "$REQ" "$URI" | jq -r '.'
}

createRDSSnapshot() {
	[ $# -eq 3 ] && createRDSSnapshotImpl "$@"
	[ $# -ne 3 ] && echo "ERROR: Please specify instance id, name and a description of the snapshot" 1>&2
}

deleteRDSSnapshot() {
	if [ $# -eq 1 ]; then
		local backupId=$1
		local URI="${AUTH_URL_RDS_PROJECT}/backups/${backupId}"
		curldeleteauth_language $TOKEN $URI | jq .
	else
		echo "ERROR: Please specify snapshot/backup id to delete" 1>&2
	fi
}

listDomains() {
   setlimit 100
	#setlimit; setapilimit 500 100 zones
	#curlgetauth $TOKEN $AUTH_URL_DNS$PARAMSTRING | jq -r '.'
	curlgetauth $TOKEN $AUTH_URL_DNS$PARAMSTRING | jq -r 'def str(s): s|tostring; .zones[] | .id+"   "+.name+"   "+.status+"   "+.zone_type+"   "+str(.ttl)+"   "+str(.record_num)+"   "+.description'
}

# Params: NAME [DESC [TYPE [EMAIL [TTL]]]]
createDomain() {
	if test "${1: -1:1}" != "."; then
		echo "WARN: Name should end in '.'" 1>&2
	fi
	REQ="{ \"name\": \"$1\""
	if test -n "$2"; then REQ="$REQ, \"description\": \"$2\""; fi
	if test -n "$3"; then REQ="$REQ, \"zone_type\": \"$3\""; fi
	if test -n "$4"; then REQ="$REQ, \"email\": \"$4\""; fi
	if test -n "$5"; then REQ="$REQ, \"ttl\": $5"; fi
	REQ="$REQ }"
	curlpostauth $TOKEN "$REQ" $AUTH_URL_DNS | jq .
}

showDomain() {
	curlgetauth $TOKEN $AUTH_URL_DNS/$1 | jq .
}

deleteDomain() {
	curldeleteauth $TOKEN $AUTH_URL_DNS/$1 | jq .
}

# Params: ZONEID NAME TYPE TTL VAL[,VAL] [DESC]
addRecord() {
	if test -z "$5"; then
		echo "ERROR: Need to provide more params" 1>&2
		exit 1
	fi
	case "$3" in
		A|AAAA|MX|PTR|CNAME|NS|TXT)
			;;
		*)
			echo "WARN: Unknown record type \"$3\"" 1>&2
			;;
	esac
	if test "${2: -1:1}" != "."; then
		echo "WARN: Name should end in '.'" 1>&2
	fi
	REQ="{ \"name\": \"$2\", \"type\": \"$3\", \"ttl\": $4"
	if test -n "$6"; then REQ="$REQ, \"description\": \"$6\""; fi
	OLDIFS="$IFS"
	VLAS=""
	IFS=","
	for val in $5; do VALS="$VALS \"$val\","; done
	IFS="$OLDIFS"
	REQ="$REQ, \"records\": [ ${VALS%,} ] }"
	curlpostauth $TOKEN "$REQ" $AUTH_URL_DNS/$1/recordsets | jq '.'
}

showRecord() {
	curlgetauth $TOKEN $AUTH_URL_DNS/$1/recordsets/$2 | jq '.'
}

listRecords() {
	# TODO pagination
	if test -z "$1"; then
		curlgetauth $TOKEN "${AUTH_URL_DNS%zones}recordsets"  | jq -r 'def str(s): s|tostring; .recordsets[] | .id+"   "+.name+"   "+.status+"   "+.type+"   "+str(.ttl)+"   "+str(.records)' | arraytostr
	else
		curlgetauth $TOKEN "$AUTH_URL_DNS/$1/recordsets" | jq -r 'def str(s): s|tostring; .recordsets[] | .id+"   "+.name+"   "+.status+"   "+.type+"   "+str(.ttl)+"   "+str(.records)' | arraytostr
	fi
}

deleteRecord() {
	curldeleteauth $TOKEN "$AUTH_URL_DNS/$1/recordsets/$2" | jq .
}

# concatenate array using $1 as concatenation token
concatarr() {
	ans=""
	delim="$1"
	shift
	for str in "$@"; do
		ans="$ans$delim$str"
	done
	echo "$ans"
}

getIMAGEList() {
	IMAGE_FILTER=$(concatarr "&" "$@")
	IMAGE_FILTER="${IMAGE_FILTER// /%20}"
	#setlimit 800
	setlimit; setapilimit 1600 100 images
   if test -z "$PARAMSTRING" -a -n "$IMAGE_FILTER"; then IMAGE_FILTER="?${IMAGE_FILTER:1}"; fi
	curlgetauth_pag $TOKEN "$AUTH_URL_IMAGES$PARAMSTRING$IMAGE_FILTER"| jq 'def str(v): v|tostring; .images[] | .id +"   "+.name+"   "+.status+"   "+str(.min_disk)+"   "+.visibility+"   "+.__platform ' | tr -d '"'
}

getIMAGEDetail() {
	if ! is_uuid "$1"; then convertIMAGENameToId "$1"; else IMAGE_ID="$1"; fi
	#curlgetauth $TOKEN "$AUTH_URL_IMAGES?limit=800"| jq '.images[] | select(.id == "'$IMAGE_ID'")'
	curlgetauth $TOKEN "$AUTH_URL_IMAGES/$IMAGE_ID"| jq '.'
}

registerIMAGE() {
	if test -z "$1"; then echo "ERROR: Need to specify NAME" 1>&2; exit 2; fi
	if test -z "$2"; then echo "ERROR: Need to specify OBSBucket" 1>&2; exit 2; fi
	if test -z "$MINDISK"; then echo "ERROR: Need to specify --min-disk" 1>&2; exit 2; fi
	if test -z "$MINRAM"; then MINRAM=1024; fi
	if test -z "$DISKFORMAT"; then DISKFORMAT="${2##*.}"; fi
	if test -z "$DISKFORMAT" -o "$DISKFORMAT" = "zvhd"; then DISKFORMAT="vhd"; fi
	unset OSVJSON
	if test -n "$OSVERSION"; then OSVJSON="\"os_version\": \"$OSVERSION\","; fi
	OLDIFS="$IFS"; IFS=","
	for prop in $PROPS; do
		val="${prop##*=}"
		case $val in
			[0-9]*|false|False|true|True)
				pstr=`echo "$prop" | sed 's/^_*\([^=]*\)=\(.*\)$/"\1": \2/'`
				;;
			*)
				pstr=`echo "$prop" | sed 's/^_*\([^=]*\)=\(.*\)$/"\1": "\2"/'`
				;;
		esac
		OSVJSON="$OSVJSON $pstr,"
	done < <( echo "$PROPS")
	IFS="$OLDIFS"
	REQ="{ $OSVJSON  \"min_disk\": $MINDISK, \"min_ram\": $MINRAM,
		\"disk_format\": \"$DISKFORMAT\", \"name\": \"$1\", \"image_url\": \"$2\" }"
	IMGTASKID=`curlpostauth $TOKEN "$REQ" "$AUTH_URL_IMAGESV2/action" | jq '.job_id' | cut -d':' -f 2 | tr -d '" '`
	WaitForTaskFieldOpt $IMGTASKID '.entities.image_id' 5 150
}

createIMAGE() {
	if test -z "$DISKFORMAT"; then DISKFORMAT="vhd"; fi
	if test -z "$MINDISK" -a -z "$INSTANCE_ID"; then echo "ERROR: Need to specify --min-disk OR --instance-id" 1>&2; exit 2; fi
	if test -z "$MINRAM"; then MINRAM=1024; fi
	if test -n "$1"; then IMAGENAME="$1"; fi
	if test -z "$IMAGENAME"; then echo "ERROR: Need to specify NAME with --image-name" 1>&2; exit 2; fi
	unset OSVJSON
	if test -n "$OSVERSION"; then OSVJSON="\"__os_version\": \"$OSVERSION\","; fi
	OLDIFS="$IFS"; IFS=","
	for prop in $PROPS; do
		val="${prop##*=}"
		case $val in
			[0-9]*|false|False|true|True)
				pstr=`echo "$prop" | sed 's/^\([^=]*\)=\(.*\)$/"\1": \2/'`
				;;
			*)
				pstr=`echo "$prop" | sed 's/^\([^=]*\)=\(.*\)$/"\1": "\2"/'`
				;;
		esac
		OSVJSON="$OSVJSON $pstr,"
	done < <( echo "$PROPS")
	IFS="$OLDIFS"
	if test -z "$INSTANCE_ID"; then
		# Create fresh image
		REQ="{ $OSVJSON  \"container_format\": \"bare\",
			\"disk_format\": \"$DISKFORMAT\", \"min_disk\": $MINDISK,
			\"min_ram\": $MINRAM, \"name\": \"$IMAGENAME\",
			\"visibility\": \"private\", \"protected\": false }"
		if test -n "$DESCRIPTION"; then REQ="${REQ%\}}, \"description\": \"$DESCRIPTION\" }"; fi
		curlpostauth $TOKEN "$REQ" "$AUTH_URL_IMAGES" | jq '.' #'.[]'
	else
		# Create VM snapshot image
		REQ="{ \"name\": \"$IMAGENAME\", \"instance_id\": \"$INSTANCE_ID\" }"
		if test -n "$DESCRIPTION"; then REQ="${REQ%\}}, \"description\": \"$DESCRIPTION\" }"; fi
		RESP=$(curlpostauth $TOKEN "$REQ" "$AUTH_URL_IMAGESV2/action" | jq '.')
		echo "$RESP"
		IMGTASKID=`echo "$RESP" | jq '.job_id' | cut -d':' -f 2 | tr -d '" '`
		IMGID=`WaitForTaskFieldOpt $IMGTASKID '.entities.image_id' 5 120 | tail -n1`
		if is_uuid "$IMGID"; then getIMAGEDetail $IMGID; fi
	fi
}

deleteIMAGE() {
	if ! is_uuid "$1"; then convertIMAGENameToId "$1"; else IMAGE_ID="$1"; fi
	curldeleteauth $TOKEN "$AUTH_URL_IMAGES/$IMAGE_ID"
}

uploadIMAGEobj()
{
	# The image upload via s3 bucket has been moved to v1 endpoint
	ANS=$(curlputauth $TOKEN "{ \"image_url\":\"$2\" }" "$AUTH_URL_IMAGESV1/$1/upload")
	# Fall back to intermediate solution which abused the v2 OpenStack API
	case "$ANS" in
	*"Api does not exist"*)
		curlputauth $TOKEN "{ \"image_url\":\"$2\" }" "$AUTH_URL_IMAGES/$1/file"
		;;
	*)
		echo "$ANS"
		;;
	esac
}

uploadIMAGEfile()
{
	sz=$(stat -c "%s" "$2")
	echo "INFO: Uploading $sz bytes from $2 to image $1 ..." 1>&2
	curlputauthbinfile $TOKEN "$2" "$AUTH_URL_IMAGES/$1/file"
}

IMGJOBID=""
downloadIMAGE()
{
	if test -z "$DISKFORMAT"; then DISKFORMAT="${2##*.}"; fi
	IMSANS=`curlpostauth $TOKEN "{ \"bucket_url\": \"$2\", \"file_format\": \"$DISKFORMAT\" }" "$AUTH_URL_IMAGESV1/$1/file"`
	echo "$IMSANS"
	IMGJOBID=`echo "$IMSANS" | jq '.job_id' | cut -d':' -f 2 | tr -d '" '`
}

updateIMAGE()
{
	# FIXME: This only updates one single value at a time, could be optimized a lot
	OLDIFS="$IFS"; IFS=","
	for prop in $PROPS; do
		curladdorreplace $TOKEN "$AUTH_URL_IMAGES/$1" "${prop%%=*}" "${prop#*=}" "application/openstack-images-v2.1-json-patch"
	done
	IFS="$OLDIFS"
	# NOW handle min_disk, min_ram, name (if any change)
	if test -n "$MINDISK"; then
		curladdorreplace $TOKEN "$AUTH_URL_IMAGES/$1" "min_disk" "$MINDISK" "application/openstack-images-v2.1-json-patch"
	fi
	if test -n "$MINRAM"; then
		curladdorreplace $TOKEN "$AUTH_URL_IMAGES/$1" "min_ram" "$MINRAM" "application/openstack-images-v2.1-json-patch"
	fi
	if test -n "$IMAGENAME"; then
		curladdorreplace $TOKEN "$AUTH_URL_IMAGES/$1" "name" "$IMAGENAME" "application/openstack-images-v2.1-json-patch"
	fi
}

getImgMemberList()
{
	curlgetauth $TOKEN "$AUTH_URL_IMAGES/$1/members" | jq -r '.members[] | .member_id+"   "+.image_id+"   "+.status'
}

getImgMemberDetail()
{
	curlgetauth $TOKEN "$AUTH_URL_IMAGES/$1/members/$2" | jq -r '.'
}

ImgMemberCreate()
{
	curlpostauth $TOKEN "{ \"member\": \"$2\" }" "$AUTH_URL_IMAGES/$1/members" | jq -r '.'
}

ImgMemberDelete()
{
	curldeleteauth $TOKEN "$AUTH_URL_IMAGES/$1/members/$2"
}

ImgMemberAccept()
{
	PRJ=${2:-$OS_PROJECT_ID}
	curlputauth $TOKEN "{ \"status\": \"accepted\" }" "$AUTH_URL_IMAGES/$1/members/$PRJ" | jq -r '.'
}

ImgMemberReject()
{
	PRJ=${2:-$OS_PROJECT_ID}
	curlputauth $TOKEN "{ \"status\": \"rejected\" }" "$AUTH_URL_IMAGES/$1/members/$PRJ" | jq -r '.'
}



getFLAVORListOld() {
	#setlimit 500
	setlimit; setapilimit 720 30 flavors
	curlgetauth_pag $TOKEN "$AUTH_URL_FLAVORS$PARAMSTRING" | jq '.[]'
#| python -m json.tool
}

getFLAVORList() {
	#curlgetauth $TOKEN "$AUTH_URL_FLAVORS?limit=500" | jq '.flavors[]'
	#setlimit 500
	setlimit; setapilimit 720 30 flavors
	curlgetauth_pag $TOKEN "$AUTH_URL_FLAVORS$PARAMSTRING" | jq '.flavors[] | "\(.id)   \(.name)   \(.vcpus)   \(.ram)   \(.os_extra_specs)"'  | sed -e 's/{*\\"}*//g' -e 's/,/ /g'| tr -d '"'
#| python -m json.tool
}

getKEYPAIRList() {
	#curlgetauth $TOKEN "$AUTH_URL_KEYNAMES?limit=800" | jq '.'
	#setlimit 800
	setlimit; setapilimit 1080 40 keypairs
	curlgetauth_pag $TOKEN "$AUTH_URL_KEYNAMES$PARAMSTRING" | jq '.keypairs[] | .keypair | .name+"   "+.fingerprint' | tr -d '"'
#| python -m json.tool
}

getKEYPAIR() {
	curlgetauth $TOKEN "$AUTH_URL_KEYNAMES/$1" | jq '.[]'
#| python -m json.tool
}

createKEYPAIR() {
	if test -n "$2"; then PKEY="\"public_key\": \"$2\", "; fi
	curlpostauth $TOKEN "{ \"keypair\": { $PKEY \"name\": \"$1\" } }" "$AUTH_URL_KEYNAMES" | jq '.'
}

deleteKEYPAIR() {
	curldeleteauth $TOKEN "$AUTH_URL_KEYNAMES/$1"
}

createELB() {
	if test -n "$3"; then BANDWIDTH=$3; fi
	if test -n "$2"; then NAME="$2"; fi
	if test -n "$1"; then VPCID=$1; fi
	if [ -z "$VPCID" -a -n "$VPCNAME" ]; then convertVPCNameToId "$VPCNAME"; fi
	if test -z "$VPCID"; then echo "ERROR: Need to specify VPC" 1>&2; exit 1; fi
	ELBTYPE='"type": "External", "bandwidth": "'$BANDWIDTH'"'
	DEFNAME="ELB-$BANDWIDTH"
	if  test -n "$SUBNETID" -o -n "$SUBNETNAME"; then
		if [ "$SUBNETNAME" != "" ] && [ "$SUBNETID" == "" ]; then
			convertSUBNETNameToId $SUBNETNAME $VPCID
		fi
		if [ "$SECUGROUPNAME" != "" ] && [ "$SECUGROUP" == "" ]; then
			convertSECUGROUPNameToId "$SECUGROUPNAME"
		fi
		if test -z "$AZ"; then
			if test -n "$SUBNETAZ"; then
				AZ="$SUBNETAZ"
			else
				echo "ERROR: Need to specify AZ (or derive from subnet)" 1>&2
				exit 2
			fi
		fi
		if test -n "$SUBNETAZ" -a "$SUBNETAZ" != "$AZ"; then
			echo "WARN: AZ ($AZ) does not match subnet's AZ ($SUBNETAZ)" 1>&2
		fi
		# TODO: FIXME: need to get these IDs through the API -- values are valid only for OTC Prod
		if test "$OS_CLOUD_ENV" == "otc"; then
			if [[ $AZ == 'eu-de-01' ]]; then
				AZID='bf84aba586ce4e948da0b97d9a7d62fb'
			elif [[ $AZ == 'eu-de-02' ]]; then
				AZID='bf84aba586ce4e948da0b97d9a7d62fc'
			else
				echo "WARN: No IDs known for cloud AZ $AZ" 1>&2
				AZID="$AZ"
			fi
		else
			echo "WARN: No IDs known for cloud env $OS_CLOUD_ENV" 1>&2
			AZID="$AZ"
		fi
		ELBTYPE='"type": "Internal", "vip_subnet_id": "'$SUBNETID'", "az": "'$AZID'"'
		if test -n "$SECUGROUP"; then
			ELBTYPE="$ELBTYPE, \"security_group_id\": \"$SECUGROUP\""
		else
			echo "WARN: Need to specify --security-group-name/id" 1>&2
		fi
		DEFNAME="ELB-Int"
	fi
	if test -z "$NAME"; then
		if test -z "$INSTANCE_NAME"; then NAME="$DEFNAME"; else NAME="$INSTANCE_NAME"; fi
	fi
	ELBJOBID=`curlpostauth $TOKEN "{ \"name\": \"$NAME\", \"description\": \"LB\", \"vpc_id\": \"$VPCID\", $ELBTYPE, \"admin_state_up\": 1 }" "$AUTH_URL_ELB_LB" | jq '.job_id' | cut -d':' -f 2 | tr -d '" '`
	export ELBJOBID
}

getELBList() {
	#curlgetauth $TOKEN "$AUTH_URL_ELB_LB?limit=500" | jq '.'
	#setlimit 500
	setlimit; setapilimit 500 40 loadbalancers
	curlgetauth_pag $TOKEN "$AUTH_URL_ELB_LB$PARAMSTRING" | jq '.loadbalancers[] | .id+"   "+.name+"   "+.status+"   "+.type+"   "+.vip_address+"   "+.vpc_id' | tr -d '"'

}

getELBDetail() {
	curlgetauth $TOKEN "$AUTH_URL_ELB_LB/$1" | jq '.'
}

deleteELB() {
	ELBJOBID=`curldeleteauth $TOKEN "$AUTH_URL_ELB_LB/$1" | jq '.job_id' | cut -d':' -f 2 | tr -d '" '`
	export ELBJOBID
}

getListenerList() {
	#curlgetauth $TOKEN "$AUTH_URL_ELB/listeners?loadbalancer_id=$1" | jq '.[]'
	# TODO limits?
	curlgetauth $TOKEN "$AUTH_URL_ELB/listeners?loadbalancer_id=$1" | jq 'def str(v): v|tostring; .[] | .id+"   "+.name+"   "+.status+"   "+.protocol+":"+str(.port)+"   "+.backend_protocol+":"+str(.backend_port)+"   "+.loadbalancer_id' | tr -d '"'
}

getListenerDetail()
{
	#curlgetauth $TOKEN "$AUTH_URL_ELB/listeners?loadbalancer_id=$1" | jq '.[] | select(.id = "$2")'
	curlgetauth $TOKEN "$AUTH_URL_ELB/listeners/$1" | jq '.'
}

deleteListener() {
	curldeleteauth $TOKEN "$AUTH_URL_ELB/listeners/$1"
}

# echo "otc elb addlistener <eid> <name> <proto> <port> [<alg> [<beproto> [<beport>]]]"
createListener() {
	ALG="$5"
	BEPROTO="$6"
	BEPORT=$7
	if test -z "$ALG"; then ALG="source"; fi
	if test -z "$BEPROTO"; then BEPROTO="$3"; fi
	if test -z "$BEPORT"; then BEPORT=$4; fi
	if test "$3" = "HTTP" -o "$3" = "HTTPS"; then STICKY="\"session_sticky\": \"true\", "; fi
	curlpostauth $TOKEN "{ \"name\": \"$2\", \"loadbalancer_id\": \"$1\", \"protocol\": \"$3\", \"port\": $4, \"backend_protocol\": \"$BEPROTO\", \"backend_port\": $BEPORT, $STICKY\"lb_algorithm\": \"$ALG\" }" "$AUTH_URL_ELB/listeners" | jq '.[]'

}

#echo "otc elb addcheck <lid> <proto> <port> <int> <to> <hthres> <uthres> [<uri>]"
createCheck() {
	HTHR="$6"
	UTHR="$7"
	if test -z "$HTHR"; then HTHR=3; fi
	if test -z "$UTHR"; then UTHR=$HTHR; fi
	URI="$8"
	if test "$2" = "HTTP" -o "$2" = "HTTPS" && test -z "$URI"; then URI="/"; fi
	if test -n "$URI"; then URI="\"healthcheck_uri\": \"$URI\", "; fi

	curlpostauth "$TOKEN" "{ \"listener_id\": \"$1\", \"healthcheck_protocol\": \"$2\", $URI\"healthcheck_connect_port\": $3, \"healthcheck_interval\": $4, \"healthcheck_timeout\": $5, \"healthy_threshold\": $HTHR, \"unhealthy_threshold\": $UTHR }" "$AUTH_URL_ELB/healthcheck" | jq '.[]'
}

deleteCheck() {
	curldeleteauth $TOKEN "$AUTH_URL_ELB/healthcheck/$1"
}

getCheck() {
	curlgetauth $TOKEN "$AUTH_URL_ELB/healthcheck/$1" | jq '.'
}

#   echo "otc elb listmember <lid>"
getMemberList() {
	#curlgetauth $TOKEN "$AUTH_URL_ELB/listeners/$1/members" | jq '.'
	#curlgetauth $TOKEN "$AUTH_URL_ELB/listeners/$1/members" | jq 'def str(v): v|tostring; .[] | .id+"   "+.server_address+"   "+.status+"   "+.address+"   "+.health_status+"   "+str(.listeners)' | tr -d '"'
	curlgetauth $TOKEN "$AUTH_URL_ELB/listeners/$1/members" | jq 'def str(v): v|tostring; .[] | .id+"   "+.server_address+"   "+.status+"   "+.address+"   "+.health_status' | tr -d '"'
}

getMemberDetail() {
	curlgetauth $TOKEN "$AUTH_URL_ELB/listeners/$1/members" | jq ".[] | select(.id == \"$2\")"
}

#   echo "otc elb addmember <lid> <vmid> <vmip>"
createMember() {
	curlpostauth $TOKEN "[ { \"server_id\": \"$2\", \"address\": \"$3\" } ]" "$AUTH_URL_ELB/listeners/$1/members"
	#TODO JOB_ID ...
}

#   echo "otc elb delmember <lid> <mid> <addr>"
deleteMember() {
	curlpostauth $TOKEN "{ \"removeMember\": [ { \"id\": \"$2\", \"address\": \"$3\" } ] }" "$AUTH_URL_ELB/listeners/$1/members/action"
	#TODO JOB_ID ...
}

getECSJOBList() {
	if test -z "$1"; then echo
		echo "ERROR: Need to pass job ID to getECSJOBList" 1>&2
		exit 1
	fi
	#curlgetauth $TOKEN "$AUTH_URL_ECS_JOB/$1"

	ECSJOBSTATUSJSON=`curlgetauth "$TOKEN" "$AUTH_URL_ECS_JOB/$1"`
	#echo $ECSJOBSTATUSJSON
	ECSJOBSTATUS=`echo $ECSJOBSTATUSJSON| jq '.status'|head -n 1 |cut -d':' -f 2 | tr -d '"'| tr -d ' '`

	export ECSJOBSTATUS
}

getFileContentJSON() {
	INJECTFILE=$1
	if [ "$INJECTFILE" != "" ];then
		IFS='=' read -a FILE_AR <<< "${INJECTFILE}"
		FILENAME_NAME=${FILE_AR[1]}
		TARGET_FILENAME=${FILE_AR[0]}
		FILECONTENT=$( base64 "$FILENAME_NAME" )
		FILE_TEMPLATE='{ "path": "'"$TARGET_FILENAME"'", "contents": "'"$FILECONTENT"'" }'

		export FILEJSONITEM="$FILE_TEMPLATE"
	fi
}

getPersonalizationJSON() {
	if [ "$FILE1" != "" ]; then
		getFileContentJSON $FILE1
		FILECOLLECTIONJSON="$FILEJSONITEM"
	fi
	if [ "$FILE2" != "" ]; then
		getFileContentJSON $FILE2
		FILECOLLECTIONJSON="$FILECOLLECTIONJSON,$FILEJSONITEM"
	fi
	if [ "$FILE3" != "" ]; then
		getFileContentJSON $FILE3
		FILECOLLECTIONJSON="$FILECOLLECTIONJSON,$FILEJSONITEM"
	fi
	if [ "$FILE4" != "" ]; then
		getFileContentJSON $FILE4
		FILECOLLECTIONJSON="$FILECOLLECTIONJSON,$FILEJSONITEM"
	fi
	if [ "$FILE5" != "" ]; then
		getFileContentJSON $FILE5
		FILECOLLECTIONJSON="$FILECOLLECTIONJSON,$FILEJSONITEM"
	fi

	export PERSONALIZATION=""
	if [ "$FILECOLLECTIONJSON" != "" ]; then
		export PERSONALIZATION='"personality": [ '"$FILECOLLECTIONJSON"'],'
	fi
}

ECSAttachVolumeListName() {
	local dev_vol ecs="$1" DEV_VOL="$2"
	for dev_vol in $(echo $DEV_VOL | sed 's/,/ /g'); do
		volume_az=$(getEVSDetail ${dev_vol#*:} | jq .availability_zone)
		if [ $AZ == ${volume_az//\"/} ]; then
			ECSAttachVolumeName "$ecs" $dev_vol
		else
			echo "WARN: availablity zone of ECS ${ecs} does not correspond to availabilty zone of volume ${dev_vol}, NOT ATTACHING"
		fi
	done
}

ECSAttachVolumeName() {
	local server_name="$1" dev_vol="$2" ecsid volid
	ecsid=$(getECSList |  while read id name x; do [ "$name" = "$server_name"  -o "$id" = "$server_name"  ] && echo $id && break; done)
	volid=$(getEVSList |  while read id name x; do [ "$name" = "${dev_vol#*:}" -o "$id" = "${dev_vol#*:}" ] && echo $id && break; done)
	[ -z "$volid" ] && echo "$ERROR: volume '${dev_vol#*:}' doesn't exist" 1>&2 && return 1
	ECSAttachVolumeId  "$ecsid"  "${dev_vol%:*}:$volid"
}

# future: evs attach ecs dev:vol[,dev:vol[..]]
# today:  evs attach ecs dev:vol
ECSAttachVolumeId() {
	local server_id="$1" dev_vol="$2" dev vol req
	IFS=: read dev vol <<< "$dev_vol"
	if test -z "$vol"; then
		echo "ERROR: wrong usage of ECSAttachVolumeId(): '$dev_vol' should be 'device:VolumeID'" 1>&2
		exit 2
	fi
	dev="/dev/${dev#/dev/}"
	req='{
            "volumeAttachment": {
                "volumeId": "'"$vol"'",
                "device": "'"$dev"'"
            }
	}'
	curlpostauth "$TOKEN" "$req" "$AUTH_URL_ECS_CLOUD/$server_id/attachvolume" | jq '.[]'
}

ECSDetachVolumeListName() {
	local dev_vol ecs="$1" DEV_VOL="$2"
	for dev_vol in $(echo $DEV_VOL | sed 's/,/ /g'); do
		volume_az=$(getEVSDetail ${dev_vol#*:} | jq .availability_zone)
		if [ $AZ != ${volume_az//\"/} ]; then
			echo "WARNING: availablity zone of ECS ${ecs} does not correspond to availabilty zone of volume ${dev_vol}, NOT ATTACHING" 1>&2
		fi
		ECSAttachVolumeName "$ecs" $dev_vol
	done
}

ECSDetachVolumeName() {
	local server_name="$1" dev_vol="$2" ecsid volid  ##### dev_vol could be of the form <device>:<volume> or just <volume>
	ecsid=$(getECSList |  while read id name x; do [ "$name" = "$server_name"  ] && echo $id && break; done)
	volid=$(getEVSList |  while read id name x; do [ "$name" = "${dev_vol#*:}" ] && echo $id && break; done)
	if test -z "$volid"; then
		echo "ERROR: could not determine volume id -- perhaps volume is not mounted or ecs name is not unique" 1>&2
		exit 2
	fi
	ECSDetachVolumeId  "$ecsid"  "${dev_vol%:*}:$volid"
}

ECSDetachVolumeId() {
	local server_id="$1" dev_vol="$2" volume         ##### dev_vol could be of the form <device>:<volumeid> or just <volumeid>
	volume="${dev_vol#*:}"
	if test -z "$volume"; then
		echo "ERROR: wrong usage of volume detach function: volume is not set" 1>&2
		exit 2
	fi
	curldeleteauth "$TOKEN" "$AUTH_URL_ECS_CLOUD/$server_id/detachvolume/$volume" | jq '.[]'
}

ECSCreate() {
	if test -n "$(echo "$INSTANCE_NAME" | sed 's/^[0-9a-zA-Z_\-]*$//')"; then
		echo "ERROR: INSTANCE_NAME may only contain letters, digits, _ and -" 1>&2
		exit 2
	fi

	getPersonalizationJSON

	if [ -n "$ROOTDISKSIZE" ]; then
		DISKSIZE=', "size": "'$ROOTDISKSIZE'"'
	else
		unset DISKSIZE
	fi
	if test -z "$AZ"; then
		if test -n "$SUBNETAZ"; then
			AZ="$SUBNETAZ"
		else
			echo "ERROR: Need to specify AZ (or derive from subnet)" 1>&2
			exit 2
		fi
	fi
	if test -n "$SUBNETAZ" -a "$SUBNETAZ" != "$AZ"; then
		echo "WARN: AZ ($AZ) does not match subnet's AZ ($SUBNETAZ)" 1>&2
	fi

	OPTIONAL=""
	if [ "$CREATE_ECS_WITH_PUBLIC_IP" == "true" ]; then
		# TODO: have to got from param
		OPTIONAL="$OPTIONAL
		\"publicip\": {
			\"eip\": {
				\"iptype\": \"5_bgp\",
				\"bandwidth\": {
					\"size\": $BANDWIDTH,
					\"sharetype\": \"PER\",
					\"chargemode\": \"traffic\"
				}
			}
		},"
	fi

	if test -n "$KEYNAME"; then
		OPTIONAL="$OPTIONAL
			\"key_name\": \"$KEYNAME\","
	fi
	if test -n "$ADMINPASS"; then
		OPTIONAL="$OPTIONAL
			\"adminPass\": \"$ADMINPASS\","
	fi
	#OPTIONAL="$OPTIONAL \"__vnckeymap\": \"en\","
	if test -z "$NUMCOUNT"; then NUMCOUNT=1; fi

	SECUGROUPIDS=""
	for id in ${SECUGROUP//,/ }; do
		SECUGROUPIDS="$SECUGROUPIDS { \"id\": \"$id\" },"
	done
	SECUGROUPIDS="${SECUGROUPIDS%,}"

	FIXEDIPJSON=""
	if test -n "$FIXEDIP"; then
		FIXEDIPJSON=", \"ip_address\": \"$FIXEDIP\""
	fi
	# TODO: Support both/multiple user data pieces
	USERDATAJSON=""
	if test -n "$USERDATA"; then
		if test "${USERDATA:0:13}" != "#cloud-config"; then echo "WARN: user-data string does not start with #cloud-config" 1>&2; fi
		USERDATAJSON="\"user_data\": \""$(echo "$USERDATA" | base64)"\","
	fi
	if test -n "$USERDATAFILE"; then
		if test -n "$USERDATAJASON"; then echo "WARN: user-data-file overrides string" 1>&2; fi
		if test "`head -n1 $USERDATAFILE`" != "#cloud-config"; then echo "WARN: user-data-file does not start with #cloud-config" 1>&2; fi
		USERDATAJSON="\"user_data\": \""$(base64 "$USERDATAFILE")"\","
	fi

   if test -n "$DATADISKS"; then
      DATA_VOLUMES=$(build_data_volumes_json $DATADISKS)
   fi

	REQ_CREATE_VM='{
		"server": {
			"availability_zone": "'"$AZ"'",
			"name": "'"$INSTANCE_NAME"'",
			"imageRef": "'"$IMAGE_ID"'",
			"root_volume": {
				"volumetype": "'"$VOLUMETYPE"'"'$DISKSIZE'
			},
         "data_volumes": ['"
            $DATA_VOLUMES
         "'],
			"flavorRef": "'"$INSTANCE_TYPE"'",
			'"$PERSONALIZATION"'
			'"$USERDATAJSON"'
			"vpcid": "'"$VPCID"'",
			"security_groups": [ '"$SECUGROUPIDS"' ],
			"nics": [ { "subnet_id": "'"$SUBNETID"'" '"$FIXEDIPJSON"' } ],
			'"$OPTIONAL"'
			"count": '$NUMCOUNT'
		}
	}'

	echo "$REQ_CREATE_VM"

	if [ "$IMAGE_ID" == "" ]; then
		echo "Image definition not Correct ! Check avaliable images with following command:" 1>&2
		echo 'otc images list' 1>&2
		exit 1
	fi
	if [ "$INSTANCE_TYPE" == "" ]; then
		echo "Instance Type definition not Correct ! Please check avaliable flavors  with following command:" 1>&2
		echo 'otc ecs flavor-list' 1>&2
		exit 1
	fi
	if [ "$VPCID" == "" ]; then
		echo "VPC definition not Correct ! Please check avaliable VPCs  with following command:" 1>&2
		echo 'otc vpc list' 1>&2
		exit 1
	fi
	if [ "$SECUGROUP" == "" ]; then
		echo "Security Group definition not Correct ! Please check avaliable security group with following command:" 1>&2
		echo 'otc security-group list' 1>&2
		exit 1
	fi
	if [ "$SUBNETID" == "" ]; then
		echo "Subnet definition not Correct ! Please check avaliable subnets with following command:" 1>&2
		echo 'otc subnet list' 1>&2
		exit 1
	fi

	ECSTASKID=`curlpostauth "$TOKEN" "$REQ_CREATE_VM" "$AUTH_URL_ECS_CLOUD" | jq '.job_id' | cut -d':' -f 2 | tr -d '" '`
	# this lines for DEBUG
	export ECSTASKID
}

ECSAction() {
	if test -z "$ECSACTIONTYPE"; then ECSACTIONTYPE="SOFT"; fi
	REQ_ECS_ACTION_VM='
	{
		"'"$ECSACTION"'": {
			"type":"'"$ECSACTIONTYPE"'",
			"servers": [ { "id": "'"$ECSACTIONSERVERID"'" } ]
		}
	}'
	export REQ_ECS_ACTION_VM
	#echo $REQ_ECS_ACTION_VM
	curlpostauth "$TOKEN" "$REQ_ECS_ACTION_VM" "$AUTH_URL_ECS_CLOUD_ACTION"
}

# OpenStack API (unused)
ECSStop() {
	REQ="{\"os-stop\":{}}"
	ECS_ACTION_STOP="$NOVA_URL/servers/$ECSACTIONSERVERID/action"
	echo $ECS_ACTION_STOP
	curlpostauth "$TOKEN" "$REQ" "$ECS_ACTION_STOP"
}

appparm()
{
	if test -z "$PARMS"; then
		PARMS="$1"
	else
		PARMS="$PARMS, $1"
	fi
}

ECSUpdate()
{
	PARMS=""
	if test -n "$INSTANCE_NAME"; then appparm "\"name\": \"$INSTANCE_NAME\""; fi
	if test -n "$IMAGENAME"; then appparm "\"image\": \"$IMAGENAME\""; fi
	OLDIFS="$IFS"; IFS=","
	for prop in $PROPS; do
		appparm "\"${prop%%=*}\": \"${prop#*=}\""
	done
	IFS="$OLDIFS"
	curlputauth $TOKEN "{ \"server\": { $PARMS } }" "$AUTH_URL_ECS/$1"
}

ECSDelete() {
	local DEV_VOL="" delete_publicip="true" delete_volume="false" id ecs
	IDS=""
	while [ $# -gt 0 ]
		do
			case "$1"
				in
					--umount)    DEV_VOL="$2"           ; shift 2;;##### works only if $ecs is a name, not an id
					--keepEIP)   delete_publicip="false"; shift  ;;
					--delVolume) delete_volume="true"   ; shift  ;;
					--wait)      WAIT_FOR_JOB="true"    ; shift  ;;
					--nowait)    WAIT_FOR_JOB="false"   ; shift  ;;
					*)           break;;
				esac
		done
	for ecs in $@; do
		# convert $ecs to an id if given ecs is a name, otherwize keep the ecs=id
		for id in $(getECSList | while read ecsid name x; do [ "$ecsid" = "$ecs" ]||[ "$name" = "$ecs" ]||continue; echo "$ecsid";done)
			do
				IDS="$IDS { \"id\": \"$id\" },"
				[ -n "$DEV_VOL" ] && ECSDetachVolumeListName "$ecs" "$DEV_VOL" ##### detach some external volumes before deleting the vm
			done
	done
	##### TODO: we have to wait here until detachments were finished -- otherwize we run into a deadlock!
	IDS="${IDS%,}"
	REQ_ECS_DELETE='{
		"servers": [ '$IDS' ],
		"delete_publicip": '$delete_publicip',
		"delete_volume": '$delete_volume'
	}'
	export REQ_ECS_DELETE
	#echo $REQ_ECS_DELETE
	ECSRESP=`curlpostauth "$TOKEN" "$REQ_ECS_DELETE" "$AUTH_URL_ECS_CLOUD_DELETE"`
	ECSTASKID=`echo "$ECSRESP" | jq '.job_id' | cut -d':' -f 2 | tr -d '" '`
	if test -n "$ECSTASKID"; then
		echo "Delete task ID: $ECSTASKID"
	else
		echo "ERROR:" 1>&2
		echo "$ECSRESP" | jq '.[]' 1>&2
		return 1
	fi
}

EVSCreate() {
	if test -n "$(echo "$VOLUME_NAME" | sed 's/^[0-9a-zA-Z_\-]*$//')"; then
		echo "ERROR: VOLUME_NAME may only contain letters, digits, _ and -" 1>&2
		exit 2
	fi

	if test -z "$AZ"; then
		if test -n "$SUBNETAZ"; then
			AZ="$SUBNETAZ"
		else
			echo "ERROR: Need to specify AZ (or derive from subnet)" 1>&2
			exit 2
		fi
	fi
	if test -n "$SUBNETAZ" -a "$SUBNETAZ" != "$AZ"; then
		echo "WARN: AZ ($AZ) does not match subnet's AZ ($SUBNETAZ)" 1>&2
	fi

	OPTIONAL=""
	if test -n "$SHAREABLE"; then
		OPTIONAL="$OPTIONAL
			\"shareable\": \"$SHAREABLE\","
	fi
	if test -n "$IMAGEREFID"; then
		OPTIONAL="$OPTIONAL
			\"imageRef\": \"$IMAGEREFID\","
	fi
	if test -n "$BACKUPID"; then
		OPTIONAL="$OPTIONAL
			\"backup_id\": \"$BACKUPID\","
	fi
	if test -z "$NUMCOUNT"; then NUMCOUNT=1; fi
	if test -z "$VOLUME_DESC"; then VOLUME_DESC=$VOLUME_NAME; fi

	REQ_CREATE_EVS='{
		"volume": {
			"count": '$NUMCOUNT',
			"availability_zone": "'$AZ'",
			"description": "'$VOLUME_DESC'",
			"size": "'$ROOTDISKSIZE'",
			"name": "'$VOLUME_NAME'",
			'"$OPTIONAL"'
			"volume_type": "'$VOLUMETYPE'"
		}
	}'

	echo "$REQ_CREATE_EVS"

	if [ "$ROOTDISKSIZE" == "" ]; then
		echo "EVS volume size is not defined! Please define a size with --disk-size" 1>&2
		exit 1
	fi

	EVSTASKID=`curlpostauth "$TOKEN" "$REQ_CREATE_EVS" "$AUTH_URL_CVOLUMES" | jq '.job_id' | cut -d':' -f 2 | tr -d '" '`
	# this lines for DEBUG
	export EVSTASKID
}

EVSDelete() {
	EVSTASKID=`curldeleteauth "$TOKEN" "$AUTH_URL_CVOLUMES/$@" | jq '.[]' | tr -d '" '`
	export EVSTASKID
}

VPCCreate() {
	REQ_CREATE_VPC='{
		"vpc": {
			"name": "'"$VPCNAME"'",
			"cidr": "'"$CIDR"'"
		}
	}'
	export REQ_CREATE_VPC
	#echo $REQ_CREATE_VPC
	curlpostauth "$TOKEN" "$REQ_CREATE_VPC" "$AUTH_URL_VPCS" | jq '.[]'
}

SUBNETCreate() {
	REQ_CREATE_SUBNET='{
		"subnet": {
			"name": "'"$SUBNETNAME"'",
			"cidr": "'"$CIDR"'",
			"gateway_ip": "'"$GWIP"'",
			"dhcp_enable": "true",
			"primary_dns": "'"$PRIMARYDNS"'",
			"secondary_dns": "'"$SECDNS"'",
			"availability_zone":"'"$AZ"'",
			"vpc_id":"'"$VPCID"'"
		}
	}'
	#echo $REQ_CREATE_SUBNET
	curlpostauth "$TOKEN" "$REQ_CREATE_SUBNET" "$AUTH_URL_SUBNETS" | jq '.[]'
}

PUBLICIPSCreate() {
	if test -z "$BANDWIDTH_NAME"; then BANDWIDTH_NAME="bandwidth-${BANDWIDTH}m-$$"; fi
	REQ_CREATE_PUBLICIPS='{
		"publicip": {
			"type": "5_bgp"
		},
		"bandwidth": {
			"name": "'"$BANDWIDTH_NAME"'",
			"size": '$BANDWIDTH',
			"share_type": "PER"
		}
	}'

	export REQ_CREATE_PUBLICIPS
	echo $REQ_CREATE_PUBLICIPS
	curlpostauth "$TOKEN" "$REQ_CREATE_PUBLICIPS" "$AUTH_URL_PUBLICIPS" | jq '.[]'
}

PUBLICIPSDelete() {
	curldeleteauth "$TOKEN" "$AUTH_URL_PUBLICIPS/$@" | jq '.[]'
}

getPortID() {
	(  getECSVM $1 | sed -n '/^\[/,/^\]/p' \
		| jq '.[] | .port_state + ";" + .fixed_ips[0].ip_address + ";" + .port_id' | tr -d \" \
		| while IFS=\; read state ip port; do [ "$state" = ACTIVE ] && [ "$ip" != "" ] && echo $port;done)
}

BindPublicIpToCreatingVM() {
	##### use ecs server id to attach volumes, external ip_addresses, ...
	while [ -z "$PRTID" ]; do sleep 5; PRTID=$(getPortID $ECSID);done
	##### input: $EIP
	EIPID=$(getPUBLICIPSList | sed 's/   /;/g' \
          |  while IFS=";" read id eip status iip bid b type;do
                   [ "$eip" = "$EIP" ]||[ "$id" = "$EIP" ]|| continue
                   [ "$status" = "DOWN" ] && echo "$id"   && break
                   echo "ERROR: requested external IP is of wrong status: $status" 1>&2
                done)
	[ -n "$EIPID" ] && PUBLICIPSBind "$EIPID" "$PRTID" \
	|| return 1
}

PUBLICIPSBind() {
	ID=$1
	PORT_ID=$2
	if test -z "$PORT_ID"; then echo "Please define port-id to which the public ip should be bound to." 1>&2; exit 1; fi
	REQ_BIND_PUBLICIPS='{
		"publicip": {
			"port_id": "'"$PORT_ID"'"
		}
	}'

	export REQ_BIND_PUBLICIPS
	echo $REQ_BIND_PUBLICIPS
	curlputauth "$TOKEN" "$REQ_BIND_PUBLICIPS" "$AUTH_URL_PUBLICIPS/$ID" | jq '.[]'
}

PUBLICIPSUnbind() {
	ID=$1
	REQ_UNBIND_PUBLICIPS='{
		"publicip": {
			"port_id": ""
		}
	}'

	export REQ_UNBIND_PUBLICIPS
	echo $REQ_UNBIND_PUBLICIPS
	curlputauth "$TOKEN" "$REQ_UNBIND_PUBLICIPS" "$AUTH_URL_PUBLICIPS/$ID" | jq '.[]'
}

SECGROUPCreate() {
	REQ_CREATE_SECGROUP='{
		"security_group": {
			"name":"'"$SECUGROUPNAME"'",
			"vpc_id" : "'"$VPCID"'"
		}
	}'
	#{ "security_group": { "name":"qq", "vpc_id" : "3ec3b33f-ac1c-4630-ad1c-7dba1ed79d85" } }
	export REQ_CREATE_SECGROUP
	echo $REQ_CREATE_SECGROUP
	curlpostauth "$TOKEN" "$REQ_CREATE_SECGROUP" "$AUTH_URL_SEC_GROUPS" | jq '.[]'
}

SECGROUPRULECreate() {
	REQ_CREATE_SECGROUPRULE='{
		"security_group_rule": {
			"direction":"'"$DIRECTION"'",
			"port_range_min":"'"$PORTMIN"'",
			"port_range_max":"'"$PORTMAX"'",
			"ethertype":"'"$ETHERTYPE"'",
			"protocol":"'"$PROTOCOL"'",
			"security_group_id":"'"$SECUGROUP"'"
		}
	}'
	#{"security_group_rule":{ "direction":"'"$DIRECTION"'", "port_range_min":"'"$PORTMIN"'", "ethertype":"'"$ETHERTYPE"'", "port_range_max":"'"$PORTMAX"'", "protocol":"'"$PROTOCOL"'", "remote_group_id":"'"$REMOTEGROUPID"'", "security_group_id":"'"$SECUGROUPID"'" } }
	#{"security_group_rule":{ "direction":"ingress", "port_range_min":"80", "ethertype":"IPv4", "port_range_max":"80", "protocol":"tcp", "remote_group_id":"85cc3048-abc3-43cc-89b3-377341426ac5", "security_group_id":"a7734e61-b545-452d-a3cd-0189cbd9747a" } }
	export REQ_CREATE_SECGROUPRULE
	echo $REQ_CREATE_SECGROUPRULE
	curlpostauth "$TOKEN" "$REQ_CREATE_SECGROUPRULE" "$AUTH_URL_SEC_GROUP_RULES" | jq '.[]'
}

# $1 = TASKID
# $2 = Field to wait for
# $3 = PollFreq (s), default 2
# $4 = MaxWait (multiples of PollFreq), default 21
WaitForTaskField() {
	if test -z "$1" -o "$1" = "null"; then echo "ERROR" 1>&2; return 1; fi
	SEC=${3:-2}
	MAXW=${4:-21}
	echo "Waiting for field $2 in job: $AUTH_URL_ECS_JOB/$1" 1>&2
	getECSJOBList $1
	RESP="$ECSJOBSTATUSJSON"
	echo "#$RESP" 1>&2
	FIELD=$(echo $ECSJOBSTATUSJSON| jq "$2" 2>/dev/null | tr -d '"')
	declare -i ctr=0
	while [ $ctr -le $MAXW ] && [ "$ECSJOBSTATUS" == "RUNNING" ] || [ "$ECSJOBSTATUS" == "INIT" ]; do
		[ -n "$FIELD" -a "$FIELD" != "null" ] && break
		sleep $SEC
		getECSJOBList $1
		FIELD=$(echo $ECSJOBSTATUSJSON| jq "$2" 2>/dev/null | tr -d '"')
		if [ "$RESP" != "$ECSJOBSTATUSJSON" ]; then
			RESP="$ECSJOBSTATUSJSON"
			echo -e "\n#$RESP" 1>&2
		else
			echo -n "." 1>&2
		fi
		let ctr+=1
	done
	echo $FIELD
	test -n "$FIELD" -a "$FIELD" != "null"
}

WaitForSubTask() {
	ECSSUBTASKID=$(WaitForTaskField $1 ".entities.sub_jobs[].job_id" $2)
}

# Wait for task to completely finish (if WAIT_FOR_JOB==true),
# optionally output field ($4), otherwise don't wait
# $1 = TASKID
# $2 = PollFreq (s), default 2s
# $3 = MaxWait (in multiples of 2xPollFreq), default 2hrs
# $4 = Field to output (optional)
WaitForTask() {
	SEC=${2:-2}
	# Timeout after 2hrs
	DEFTOUT=$((1+3600/$SEC))
	TOUT=$((2*${3:-$DEFTOUT}))
	unset FIELD
	if [ "$WAIT_FOR_JOB" == "true" ];then
		echo "Waiting for Job:   $AUTH_URL_ECS_JOB/$1" 1>&2
		getECSJOBList $1
		RESP="$ECSJOBSTATUSJSON"
		if test -n "$4"; then FIELD=$(echo $ECSJOBSTATUSJSON| jq "$4" 2>/dev/null | tr -d '"'); fi
		echo "#$RESP" 1>&2
		declare -i ctr=0
		while [ $ctr -le $TOUT ] && [ "$ECSJOBSTATUS" == "RUNNING" -o "$ECSJOBSTATUS" == "INIT" ]; do
			sleep $SEC
			getECSJOBList $1
			if test -n "$4"; then FIELD=$(echo $ECSJOBSTATUSJSON| jq "$4" 2>/dev/null | tr -d '"'); fi
			if [ "$RESP" != "$ECSJOBSTATUSJSON" ]; then
				RESP="$ECSJOBSTATUSJSON"
				echo -e "\n#$RESP" 1>&2
			else
				echo -n "." 1>&2
			fi
			let ctr+=1
		done
		if [ $ctr -gt $TOUT ]; then echo "WARN: Task $1 timed out after 2hrs" 1>&2;
		elif [ -n "$FIELD" -a "$FIELD" != "null" ]; then echo "$FIELD"; fi
	else
		getECSJOBList $1
		echo "#$ECSJOBSTATUSJSON" 1>&2
		echo "Note: Not waiting for completion, use otc task show $1 to monitor and otc task wait to wait)"
	fi
}

# Wait for full completion if WAIT_FOR_JOB is "true", not at all if set to something else,
# wait for subtask if unset
# $1 = TASKID
# $2 = Field to wait for
# $3 = PollFreq (s), optional
# $4 = MAXWAIT (multiples of POLLFREQ), optional
WaitForTaskFieldOpt() {
	if test -n "$WAIT_FOR_JOB"; then
		WaitForTask $1 $3 $4 "$2"
	else
		WaitForTaskField $1 "$2" $3 $4
	fi
}

# Does not seem to work :-(
DeleteTask() {
	curldeleteauth "$TOKEN" "$AUTH_URL_ECS_JOB/$1"
}

getUserDomainIdFromIamResponse() {
	tail -n1 | jq -r .token.user.domain.id
}

shortlistClusters() {
	curlgetauth "$TOKEN" "$AUTH_URL_CCE/api/v1/clusters" | jq -r '.[] | .metadata.uuid+"   "+.metadata.name+"   "+.spec.vpc+"   "+.spec.subnet+"   "+.spec.az'
}

listClusters() {
	curlgetauth "$TOKEN" "$AUTH_URL_CCE/api/v1/clusters" | jq '.'
}

showCluster() {
	curlgetauth "$TOKEN" "$AUTH_URL_CCE/api/v1/clusters/$1" | jq '.'
}

listClusterHosts() {
	#curlgetauth "$TOKEN" "$AUTH_URL_CCE/api/v1/clusters/$1/hosts" | jq '.'
	curlgetauth "$TOKEN" "$AUTH_URL_CCE/api/v1/clusters/$1/hosts" | jq -r '.spec.hostList[] | .spec.hostid+"   "+.message+"   "+.status+"   "+.spec.privateip+"   "+.spec.sshkey'
}

showClusterHost() {
	curlgetauth "$TOKEN" "$AUTH_URL_CCE/api/v1/clusters/$1/hosts/$2" | jq '.'
}

# CES
listMetrics() {
	PARM=""
	if test -n "$1"; then PARM="?namespace=$1"; fi
	if test -n "$2"; then PARM="$PARM&metric_name=$2"; fi
	if test -n "$3"; then PARM="$PARM&dim.0=${3/=/,}"; fi
	if test -n "$4"; then PARM="$PARM&dim.1=${4/=/,}"; fi
	if test -n "$5"; then PARM="$PARM&dim.2=${5/=/,}"; fi
	if test "${PARM:0:1}" = "&"; then PARM="?${PARM:1}"; fi
	#curlgetauth "$TOKEN" "$AUTH_URL_CES/V1.0/$OS_PROJECT_ID/metrics$PARM" | jq '.'
   # TODO: More than one metric possible
	curlgetauth "$TOKEN" "$AUTH_URL_CES/V1.0/$OS_PROJECT_ID/metrics$PARM" | jq -r 'def str(v): v|tostring; .metrics[] | .namespace+"   "+.metric_name+"   "+.unit+"   "+str(.dimensions[].value)' | arraytostr
}

listFavMetrics() {
	curlgetauth "$TOKEN" "$AUTH_URL_CES/V1.0/$OS_PROJECT_ID/favorite-metrics" | jq '.'
}

showMetrics() {
	NOW=$(date +%s)
	START=$(echo "scale=0; (${3/NOW/$NOW})*1000" | bc)
	STOP=$(echo "scale=0; (${4/NOW/$NOW})*1000" | bc)
	if test -n "$7"; then DIM="&dim.0=${7/=/,}"; else DIM=""; fi
	if test -n "$8"; then DIM="$DIM&dim.1=${8/=/,}"; fi
	if test -n "$9"; then DIM="$DIM&dim.2=${9/=/,}"; fi
	curlgetauth "$TOKEN" "$AUTH_URL_CES/V1.0/$OS_PROJECT_ID/metric-data?namespace=$1&metric_name=$2&from=$START&to=$STOP&period=$5&filter=$6$DIM" | jq '.' | sed -e 's/"timestamp": \([0-9]*\)\([0-9]\{3\}\),/"timestamp": \1.\2,/' -e 's/"timestamp": \([0-9]*\)\.000,/"timestamp": \1,/'
}

listAlarms() {
	#curlgetauth "$TOKEN" "$AUTH_URL_CES/V1.0/$OS_PROJECT_ID/alarms" | jq '.'
	#TODO: Show multiple dimensions if available
	curlgetauth "$TOKEN" "$AUTH_URL_CES/V1.0/$OS_PROJECT_ID/alarms" | jq -r 'def str(v): v|tostring; .metric_alarms[] | .alarm_id+"   "+.alarm_name+"   "+str(.alarm_enabled)+"   "+str(.metric.dimensions[].value)+"   "+.metric.namespace+" "+.metric.metric_name+" "+.condition.comparison_operator+" "+str(.condition.value)+" "+.condition.unit ' | arraytostr
}

showAlarms() {
	curlgetauth "$TOKEN" "$AUTH_URL_CES/V1.0/$OS_PROJECT_ID/alarms/$1" | jq '.'
}

showAlarmsQuotas() {
	curlgetauth "$TOKEN" "$AUTH_URL_CES/V1.0/$OS_PROJECT_ID/quotas" | jq '.'
}

deleteAlarms() {
	curldeleteauth "$TOKEN" "$AUTH_URL_CES/V1.0/$OS_PROJECT_ID/alarms/$1" | jq '.'
}

AlarmsAction() {
	curlputauth "$TOKEN" "{ \"alarm_enabled\": $1 }" "$AUTH_URL_CES/V1.0/$OS_PROJECT_ID/alarms/$2/action"
}

listTrackers() {
	#curlgetauth "$TOKEN" "$AUTH_URL_CTS/v1.0/$OS_PROJECT_ID/tracker" | jq '.'
	curlgetauth "$TOKEN" "$AUTH_URL_CTS/v1.0/$OS_PROJECT_ID/tracker" | jq -r '.[] | .tracker_name+"   "+.bucket_name+"   "+.status+"   "+.file_prefix_name'
}

listQueues() {
	#curlgetauth "$TOKEN" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues" | jq '.'
	curlgetauth "$TOKEN" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues" | jq -r 'def str(v): v|tostring; .queues[] | .id+"   "+.name+"   "+str(.produced_messages)'
}

listTopics() {
	#curlgetauth "$TOKEN" "$AUTH_URL_SMN/v2/$OS_PROJECT_ID/notifications/topics?offset=0&limit=100" | jq '.'
	setlimit 100 "offset=0"
	curlgetauth "$TOKEN" "$AUTH_URL_SMN/v2/$OS_PROJECT_ID/notifications/topics$PARAMSTRING" | jq -r '.topics[] | .topic_urn+"   "+.name+"   "+.display_name'
}

getMeta() {
	DATA=$1; shift
	if test -z "$1"; then FILT='.'; else FILT="$@"; fi
	if test ${DATA%.json} != $DATA; then PROCESS="jq $FILT"; else
		if test "$FILT" != "."; then PROCESS="grep $FILT"; else PROCESS="cat -"; fi
	fi
	RESP=$(docurl -sS "http://169.254.169.254/openstack/latest/$DATA")
	echo "$RESP" | grep "404 Not Found" >/dev/null 2>&1
	if test $? != 0 -o "$DATA" != "user_data"; then
		echo "$RESP" | $PROCESS
	fi
}

##########################################################################################

# Package dependency #####################################################################

# check libs3 installed
command -v s3 >/dev/null 2>&1 || { echo -n>&2 "Note: otc requires libs3 package to be installed for object storage operations.
Please install libs3 or libs3-2 using yum/apt-get/zypper.
Continuing anyway ..."; }

# check jq installed
command -v jq >/dev/null 2>&1 || { echo -n>&2 "ERROR: otc requires jq package to be installed.
Please install jq using yum/apt-get/zypper.
Aborting."; exit 1; }

##########################################################################################

# Command Line Parser ####################################################################

# Insecure
if test "$1" == "--insecure" -o "$1" == "-k"; then
	INS=$1; shift
else
	if test -n "$OS_CACERT"; then INS="--cacert $OS_CACERT"; else unset INS; fi
fi

# Proxy Auth
case "$HTTPS_PROXY" in
	*@*)
		if test -z "$INS"; then INS="--proxy-anyauth";
		else INS="--proxy-anyauth $INS"; fi
		;;
esac

# FIXME: Need proper position independent option parser
if test "$1" == "--domainscope"; then REQSCOPE="domain"; shift; fi

# Debugging
if test "$1" = "debug"; then DEBUG=1; shift; fi
if test "$1" = "debug"; then DEBUG=2; shift; fi

if test "$1" == "--domainscope"; then REQSCOPE="domain"; shift; fi

# fetch main command
MAINCOM=$1; shift
# fetch subcommand
SUBCOM=$1; shift

if test "$1" == "--domainscope"; then REQSCOPE="domain"; shift; fi

if test "$1" == "--limit"; then
  APILIMIT=$2; shift; shift
elif test "${1:0:8}" = "--limit="; then
  APILIMIT=${1:8}; shift
fi
if test "$1" == "--offset"; then
  APIOFFSET=$2; shift; shift
elif test "${1:0:9}" = "--offset="; then
  APIOFFSET=${1:9}; shift
fi
if test "$1" == "--marker"; then
  APIMARKER=$2; shift; shift
elif test "${1:0:9}" = "--marker="; then
  APIMARKER=${1:9}; shift
fi
if test "$1" == "--limit"; then
  APILIMIT=$2; shift; shift
elif test "${1:0:8}" = "--limit="; then
  APILIMIT=${1:8}; shift
fi

if test "$1" == "--maxgetkb"; then
  MAXGETKB=$2; shift; shift;
elif test "${1:0:11}" = "--maxgetkb="; then
  MAXGETKB=${1:11}; shift
fi

if test "$1" == "--domainscope"; then REQSCOPE="domain"; shift; fi

#if [ "$MAINCOM" == "ecs" ] && [ "$SUBCOM" == "create" ] || [ "$MAINCOM" == "vpc" ] && [ "$SUBCOM" == "create" ];then
if [ "$SUBCOM" == "create" -o "$SUBCOM" == "update" -o "$SUBCOM" == "register" -o "$SUBCOM" == "download" ] || [[ "$SUBCOM" == *-instances ]]; then
	while [[ $# > 0 ]]
	do
		key="$1"

		case $key in
			-a|--admin-pass)
			ADMINPASS="$2"
			shift # past argument
			;;
			-n|--instance-name)
			INSTANCE_NAME="$2"
			shift # past argument
			;;
			-t|--instance-id)
			INSTANCE_ID="$2"
			shift # past argument
			;;
			--volume-name)
			VOLUME_NAME="$2"
			shift # past argument
			;;
			--volume-description)
			VOLUME_DESC="$2"
			shift # past argument
			;;
			--file1)
			FILE1="$2"
			shift # past argument
			;;
			--file2)
			FILE2="$2"
			shift # past argument
			;;
			--file3)
			FILE3="$2"
			shift # past argument
			;;
			--file4)
			FILE4="$2"
			shift # past argument
			;;
			--file5)
			FILE5="$2"
			shift # past argument
			;;
			-t|--instance-type)
			INSTANCE_TYPE="$2"
			shift # past argument
			;;
			-i|--image-name)
			IMAGENAME="$2"
			shift # past argument
			;;
			--image-id)
			IMAGE_ID="$2"
			shift # past argument
			;;
			-c|--count)
			NUMCOUNT="$2"
			shift # past argument
			;;
			-b|--subnet-id)
			SUBNETID="$2"
			shift # past argument
			;;
			--subnet-name)
			SUBNETNAME="$2"
			shift # past argument
			;;
			-v|--vpc-id)
			VPCID="$2"
			shift # past argument
			;;
			--vpc-name)
			VPCNAME="$2"
			shift # past argument
			;;
			--cidr)
			CIDR="$2"
			shift # past argument
			;;
			--gateway-ip)
			GWIP="$2"
			shift # past argument
			;;
			--primary-dns)
			PRIMARYDNS="$2"
			shift # past argument
			;;
			--secondary-dns)
			SECDNS="$2"
			shift # past argument
			;;
			-z|--availability-zone|--az)
			AZ="$2"
			shift # past argument
			;;
			-s|--security-group-ids)
			SECUGROUP="$2"
			shift # past argument
			;;
			-g|--security-group-name)
			SECUGROUPNAME="$2"
			shift # past argument
			;;
			-p|--public)   case "$2" in
										true|false)  CREATE_ECS_WITH_PUBLIC_IP="$2";;
										[0-9]*)      CREATE_ECS_WITH_PUBLIC_IP=false; EIP="$2";;
										*)           echo "ERROR: unsupported value for public IPs" 1>&2; exit 2;;
								esac
								shift;;     # past argument
			--volumes)     DEV_VOL="$2"
								shift;;     # past argument
			--disktype|--disk-type)
			VOLUMETYPE="$2"
			shift # past argument
			;;
			--disksize|--disk-size)
			ROOTDISKSIZE="$2"
			shift # past argument
			;;
			--datadisks)
			DATADISKS="$2"
			shift # past argument
			;;
			--direction)
			DIRECTION="$2"
			shift # past argument
			;;
			--portmin|--port-min)
			PORTMIN="$2"
			shift # past argument
			;;
			--portmax|--port-max)
			PORTMAX="$2"
			shift # past argument
			;;
			--protocol)
			PROTOCOL="$2"
			shift # past argument
			;;
			--ethertype|--ether-type)
			ETHERTYPE="$2"
			shift # past argument
			;;
			--key-name)
			KEYNAME="$2"
			shift # past argument
			;;
			--bandwidth-name)
			BANDWIDTH_NAME=$2
			shift # past argument
			;;
			--bandwidth)
			BANDWIDTH=$2
			shift # past argument
			;;
			--wait)
			WAIT_FOR_JOB="true"
			;;
			--nowait)
			WAIT_FOR_JOB="false"
			;;
			--hard)
			ECSACTIONTYPE="HARD"
			;;
			--soft)
			ECSACTIONTYPE="SOFT"
			;;
			--fixed-ip)
			FIXEDIP=$2
			shift
			;;
			--user-data)
			USERDATA=$2
			shift
			;;
			--user-data-file)
			USERDATAFILE=$2
			shift
			;;
			--default)
			DEFAULT=YES
			;;
			--min-disk)
			MINDISK=$2
			shift
			;;
			--min-ram)
			MINRAM=$2
			shift
			;;
			--disk-format|--diskformat)
			DISKFORMAT=$2
			shift
			;;
			--os-version)
			OSVERSION="$2"
			shift
			;;
			--property)
			if test -z "$PROPS"; then PROPS="$2"; else PROPS="$PROPS,$2"; fi
			shift
			;;
			--description)
			DESCRIPTION="$2"
			shift
			;;
			--name)
			NAME="$2"
			shift
			;;
			-*)
			# unknown option
			echo "ERROR: unknown option \"$1\"" 1>&2
			exit 1
			;;
			*)
			break
			;;
		esac

		shift # past argument or value
	done
fi

##########################################################################################

# MAIN ###################################################################################

#echo "Execute $MAINCOM $SUBCOM"

if [ "$MAINCOM" == "s3" ]; then
	s3 $SUBCOM "$@"
	exit $?
fi

# Support aliases / alternative names
if [ "$MAINCOM" = "server" ]; then MAINCOM="ecs"; fi
if [ "$MAINCOM" = "vm" ]; then MAINCOM="ecs"; fi
if [ "$MAINCOM" = "volumes" ]; then MAINCOM="evs"; fi
if [ "$MAINCOM" = "volume" ]; then MAINCOM="evs"; fi
if [ "$MAINCOM" = "router" ]; then MAINCOM="vpc"; fi
if [ "$MAINCOM" = "floatingip" ]; then MAINCOM="publicip"; fi
if [ "$MAINCOM" = "eip" ]; then MAINCOM="publicip"; fi
if [ "$MAINCOM" = "image" ]; then MAINCOM="images"; fi
if [ "$MAINCOM" = "sg" ]; then MAINCOM="security-group"; fi
if [ "$MAINCOM" = "vbs" ]; then MAINCOM="backup"; fi
if [ "$MAINCOM" = "auth" ]; then MAINCOM="iam"; fi
if [ "$MAINCOM" = "metric" ]; then MAINCOM="metrics"; fi
if [ "$MAINCOM" = "alarm" ]; then MAINCOM="alarms"; fi
if [ "$MAINCOM" = "traces" ]; then MAINCOM="trace"; fi
if [ "$MAINCOM" = "notification" ]; then MAINCOM="notifications"; fi
if [ "$MAINCOM" = "queue" ]; then MAINCOM="queues"; fi
if [ "$MAINCOM" = "db" ]; then MAINCOM="rds"; fi



if [ "$MAINCOM" = "iam" -a "$SUBCOM" = "catalog" ]; then OUTPUT_CAT=1; fi
if [ "$MAINCOM" = "iam" -a "$SUBCOM" = "roles" ]; then OUTPUT_ROLES=1; fi
if [ "$MAINCOM" = "iam" -a "$SUBCOM" = "domain" ]; then OUTPUT_DOM=1; fi

if [ -n "$MAINCOM" -a "$MAINCOM" != "help" -a "$MAINCOM" != "mds" ]; then
	if [ "$MAINCOM" == "iam" ] && \
		[ "$SUBCOM" == "users" -o "$SUBCOM" == "groups" ]; then
		REQSCOPE="domain"
	fi
	getIAMToken $REQSCOPE
fi

#if [ "$MAINCOM" = "rds" -a $TROVE_OVERRIDE = 1 ]; then
#	echo "WARN: Using manually set database endpoint, not advertized in catalog" 1>&2
#fi

if [ "$MAINCOM" == "help" -o "$MAINCOM" == "-h" -o "$MAINCOM" == "--help" ]; then
	printHelp

elif [ "$MAINCOM" == "ecs" ] && [ "$SUBCOM" == "list-short" ]; then
	getShortECSList
elif [ "$MAINCOM" == "ecs" ] && [ "$SUBCOM" == "list" ]; then
	getECSList
elif [ "$MAINCOM" == "ecs" ] && [ "$SUBCOM" == "list-detail" ]; then
	getECSDetail "$1"
elif [ "$MAINCOM" == "ecs" ] && [ "$SUBCOM" == "details" ]; then
	getECSDetailsNew "$1"

elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "show" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "vm" ]; then
	getECSVM $1

elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "limits" ]; then
	getLimits

elif [ "$MAINCOM" == "ecs" ] && [ "$SUBCOM" == "create" ]; then

	if [ "$VPCNAME" != "" ]; then convertVPCNameToId "$VPCNAME"; fi
	if [ "$SUBNETNAME" != "" ]; then convertSUBNETNameToId "$SUBNETNAME" "$VPCID"; fi
	if [ "$IMAGENAME" != "" ]; then convertIMAGENameToId "$IMAGENAME"; fi
	SECUGROUPNAMELIST="$SECUGROUPNAME"
	if [ "$SECUGROUPNAMELIST" != "" ] && [ "$SECUGROUP" == "" ]; then
		SECUGROUP=$(IFS=,; for SECUGROUPNAME in $SECUGROUPNAMELIST; do convertSECUGROUPNameToId "$SECUGROUPNAME"; printf ",$SECUGROUP";done)
		SECUGROUP="${SECUGROUP#,}"
	fi

	ECSCreate "$NUMCOUNT" "$INSTANCE_TYPE" "$IMAGE_ID" "$VPCID" "$SUBNETID" "$SECUGROUP"
	echo "Task ID: $ECSTASKID"

	if [ "$NUMCOUNT" = 1 ]; then
		WaitForSubTask $ECSTASKID 5    ##### => generate $ECSSUBTASKID (to get server_id=ECSID)
		if test -n "$EIP"; then
			ECSID=null
			while [ null = "$ECSID" ]; do
				sleep 5
				getECSJOBList $ECSSUBTASKID
				ECSID=$(echo "$ECSJOBSTATUSJSON" | jq '.entities.server_id' 2>/dev/null | sed 's/"//g')
			done
			BindPublicIpToCreatingVM || echo "ERROR binding external IP $EIP" >&2
		fi
	fi

	WaitForTask $ECSTASKID 5
	ECSID=$(echo "$ECSJOBSTATUSJSON" | jq '.entities.sub_jobs[].entities.server_id' 2>/dev/null | sed 's/"//g')
	echo "ECS ID: $ECSID"
	echo "ECS Creation status: $ECSJOBSTATUS"
	[ "$NUMCOUNT" = 1 ] && [ -n "$DEV_VOL" ] && ECSAttachVolumeListName "$ECSID" "$DEV_VOL"
	if [ "$ECSJOBSTATUS" != "SUCCESS" ];then
		exit 1
	fi

elif [ "$MAINCOM" == "ecs" ] && [ "$SUBCOM" == "reboot-instances" ];then
	export ECSACTION="reboot"
	export ECSACTIONSERVERID=$1

	if [ "$ECSACTIONSERVERID" == "" ];then
		echo "ERROR: Must be specify the Instance ID!" 1>&2
		printHelp
		exit 1
	fi

	ECSAction

elif [ "$MAINCOM" == "ecs" ] && [ "$SUBCOM" == "start-instances" ];then
	ECSACTION="os-start"
	ECSACTIONSERVERID=$1
	if [ "$ECSACTIONSERVERID" == "" ];then
		echo "ERROR:: Must be specify the Instance ID!" 1>&2
		printHelp
		exit 1
	fi

	ECSAction

elif [ "$MAINCOM" == "ecs" ] && [ "$SUBCOM" == "stop-instances" ];then
	ECSACTION="os-stop"
	ECSACTIONSERVERID=$1

	if [ "$ECSACTIONSERVERID" == "" ];then
	echo "ERROR: Must be specify the Instance ID!" 1>&2
		printHelp
		exit 1
	fi

	ECSAction

elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "job" ] ||
     [ "$MAINCOM" == "task" -a "$SUBCOM" == "show" ]; then
	#ECSTASKID=$1
	#echo $AUTH_URL_ECS_JOB/$1
	getECSJOBList $1
	echo "$ECSJOBSTATUSJSON"

elif [ "$MAINCOM" == "task" -a "$SUBCOM" == "delete" ]; then
	DeleteTask $1
elif [ "$MAINCOM" == "task" -a "$SUBCOM" == "wait" ]; then
	WAIT_FOR_JOB=true
	WaitForTask "$@"

elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "delete" ]; then
	ECSDelete $@
	WaitForTask $ECSTASKID 5
elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "update" ]; then
	ECSUpdate $1
elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "az-list" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "listaz" ]; then
	getAZList
elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "az-show" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "showaz" ]; then
	getAZDetail "$1"

elif [ "$MAINCOM" == "vpc" ] && [ "$SUBCOM" == "list" ];then
	getVPCList
elif [ "$MAINCOM" == "vpc" ] && [ "$SUBCOM" == "show" ];then
	getVPCDetail $1
elif [ "$MAINCOM" == "vpc" ] && [ "$SUBCOM" == "delete" ];then
	VPCDelete $1
elif [ "$MAINCOM" == "vpc" ] && [ "$SUBCOM" == "create" ];then
	VPCCreate

elif [ "$MAINCOM" == "publicip" ] && [ "$SUBCOM" == "list" ];then
	getPUBLICIPSList
elif [ "$MAINCOM" == "publicip" ] && [ "$SUBCOM" == "show" ];then
	getPUBLICIPSDetail $1
elif [ "$MAINCOM" == "publicip" ] && [ "$SUBCOM" == "create" ];then
	PUBLICIPSCreate
elif [ "$MAINCOM" == "publicip" ] && [ "$SUBCOM" == "delete" ];then
	PUBLICIPSDelete $@
elif [ "$MAINCOM" == "publicip" -a "$SUBCOM" == "bind" ] ||
     [ "$MAINCOM" == "publicip" -a "$SUBCOM" == "associate" ];then
	PUBLICIPSBind $@
elif [ "$MAINCOM" == "publicip" -a "$SUBCOM" == "unbind" ] ||
     [ "$MAINCOM" == "publicip" -a "$SUBCOM" == "disassociate" ];then
	PUBLICIPSUnbind $@

elif [ "$MAINCOM" == "subnet" ] && [ "$SUBCOM" == "list" ];then
	getSUBNETList
elif [ "$MAINCOM" == "subnet" ] && [ "$SUBCOM" == "show" ];then
	getSUBNETDetail "$1"
elif [ "$MAINCOM" == "subnet" ] && [ "$SUBCOM" == "delete" ];then
	if test "$2" == "--vpc-name"; then convertVPCNameToId "$3"; fi
	if test "$2" == "--vpc-id"; then VPCID="$3"; fi
	SUBNETDelete "$1"
elif [ "$MAINCOM" == "subnet" ] && [ "$SUBCOM" == "namelist" ];then
	# FIXME -- what should this do?
	IMAGENAME=$1
	# convertSUBNETNameToId "$SUBNETNAME" "$VPIC_ID"
	# convertSECUGROUPNameToId "$SECUGROUPNAME"
	# convertIMAGENameToId "$IMAGENAME"
elif [ "$MAINCOM" == "subnet" ] && [ "$SUBCOM" == "create" ];then
	if [ "$VPCNAME" != "" ];then convertVPCNameToId "$VPCNAME"; fi
	SUBNETCreate

elif [ "$MAINCOM" == "security-group" ] && [ "$SUBCOM" == "list" ];then
	VPCNAME=$1
	if [ "$VPCNAME" != "" ]; then convertVPCNameToId "$VPCNAME"; fi
	getSECGROUPList
elif [ "$MAINCOM" == "security-group" ] && [ "$SUBCOM" == "create" ];then
	if [ "$VPCNAME" != "" ]; then convertVPCNameToId "$VPCNAME"; fi
	SECGROUPCreate
elif [ "$MAINCOM" == "security-group-rules" -a "$SUBCOM" == "list" ] ||
     [ "$MAINCOM" == "security-group" -a "$SUBCOM" == "show" ]; then
	if [ -z "$1" ]; then
		echo "ERROR: Must be specify the Security Group ID!" 1>&2
		printHelp
		exit 1
	fi
	#AUTH_URL_SEC_GROUP_RULES="${BASEURL/iam/vpc}/v1/$OS_PROJECT_ID/security-group-rules/$SECUGROUP"
	getSECGROUPRULESList $1
elif [ "$MAINCOM" == "security-group-rules" ] && [ "$SUBCOM" == "create" ];then
	if [ "$VPCNAME" != "" ];then convertVPCNameToId "$VPCNAME"; fi
	if [ "$SECUGROUPNAME" != "" ];then convertSECUGROUPNameToId "$SECUGROUPNAME"; fi
	#AUTH_URL_SEC_GROUP_RULES="${BASEURL/iam/vpc}/v1/$OS_PROJECT_ID/security-group-rules"
	SECGROUPRULECreate

elif [ "$MAINCOM" == "images" ] && [ "$SUBCOM" == "list" ];then
	getIMAGEList "$@"
elif [ "$MAINCOM" == "images" ] && [ "$SUBCOM" == "show" ];then
	getIMAGEDetail $1
elif [ "$MAINCOM" == "images" ] && [ "$SUBCOM" == "upload" ]; then
	if test -r "$2"; then
		uploadIMAGEfile $1 $2
	else
		uploadIMAGEobj $1 $2
	fi
elif [ "$MAINCOM" == "images" ] && [ "$SUBCOM" == "create" ]; then
	createIMAGE "$1"
elif [ "$MAINCOM" == "images" ] && [ "$SUBCOM" == "register" ]; then
	registerIMAGE "$1" "$2"
elif [ "$MAINCOM" == "images" ] && [ "$SUBCOM" == "delete" ]; then
	for img in "$@"; do deleteIMAGE $img; done
elif [ "$MAINCOM" == "images" ] && [ "$SUBCOM" == "update" ]; then
	updateIMAGE "$1"
elif [ "$MAINCOM" == "images" ] && [ "$SUBCOM" == "download" ]; then
	downloadIMAGE "$@"
	WaitForTask $IMGJOBID 5
elif [ "$MAINCOM" == "images" -a "$SUBCOM" == "listmember" ] ||
     [ "$MAINCOM" == "images" -a "$SUBCOM" == "listshare" ] ||
     [ "$MAINCOM" == "images" -a "$SUBCOM" == "members" ]; then
	getImgMemberList "$@"
elif [ "$MAINCOM" == "images" -a "$SUBCOM" == "showmember" ] ||
     [ "$MAINCOM" == "images" -a "$SUBCOM" == "showshare" ]; then
	getImgMemberDetail "$@"
elif [ "$MAINCOM" == "images" -a "$SUBCOM" == "addmember" ] ||
     [ "$MAINCOM" == "images" -a "$SUBCOM" == "share" ]; then
	ImgMemberCreate "$@"
elif [ "$MAINCOM" == "images" -a "$SUBCOM" == "delmember" ] ||
     [ "$MAINCOM" == "images" -a "$SUBCOM" == "unshare" ]; then
	ImgMemberDelete "$@"
elif [ "$MAINCOM" == "images" -a "$SUBCOM" == "acceptmember" ] ||
     [ "$MAINCOM" == "images" -a "$SUBCOM" == "acceptshare" ]; then
	ImgMemberAccept "$@"
elif [ "$MAINCOM" == "images" -a "$SUBCOM" == "rejectmember" ] ||
     [ "$MAINCOM" == "images" -a "$SUBCOM" == "rejectshare" ]; then
	ImgMemberReject "$@"

elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "flavor-list" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "listflavor" ]  ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "flavors" ]; then
	getFLAVORList

elif [ "$MAINCOM" == "keypair" -a "$SUBCOM" == "list" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "listkey" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "keyname-list" ]; then
	getKEYPAIRList

elif [ "$MAINCOM" == "keypair" -a "$SUBCOM" == "show" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "showkey" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "keyname-show" ]; then
	getKEYPAIR "$@"

elif [ "$MAINCOM" == "keypair" -a "$SUBCOM" == "create" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "createkey" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "keyname-create" ]; then
	createKEYPAIR "$@"

elif [ "$MAINCOM" == "keypair" -a "$SUBCOM" == "delete" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "delkey" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "keyname-delete" ]; then
	deleteKEYPAIR "$@"


elif [ "$MAINCOM" == "iam" ] && [ "$SUBCOM" == "token" ];then
	echo $TOKEN
elif [ "$MAINCOM" == "iam" ] && [ "$SUBCOM" == "endpoints" ];then
	curlgetauth $TOKEN "${IAM_AUTH_URL%auth*}endpoints" | jq '.' #'.[]'
elif [ "$MAINCOM" == "iam" ] && [ "$SUBCOM" == "services" ];then
	curlgetauth $TOKEN "${IAM_AUTH_URL%auth*}services" | jq '.' #'.[]'
# These are not (yet) supported on OTC
elif [ "$MAINCOM" == "iam" ] && [ "$SUBCOM" == "regions" ];then
	curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/regions" | jq '.' #'.[]'
elif [ "$MAINCOM" == "iam" ] && [ "$SUBCOM" == "catalog" -o "$SUBCOM" == "domain" ];then
   echo -n ""
elif [ "$MAINCOM" == "iam" ] && [ "$SUBCOM" == "catalog2" ];then
	curlgetauth $TOKEN "${IAM_AUTH_URL%/tokens}/catalog" | jq '.' #'.[]'
elif [ "$MAINCOM" == "iam" ] && [ "$SUBCOM" == "users" ];then
	#curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/users" | jq '.' #'.[]'
	curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/users" | jq 'def tostr(s): s|tostring; .users[] | .id+"   "+.name+"   "+tostr(.enabled)+"   "+.description+"   "+.password_expires_at+"   "+.countrycode' | tr -d '"'
elif [ "$MAINCOM" == "iam" ] && [ "$SUBCOM" == "roles" ];then
   echo -n ""
elif [ "$MAINCOM" == "iam" ] && [ "$SUBCOM" == "roles2" ];then
	curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/roles" | jq '.' #'.[]'
elif [ "$MAINCOM" == "iam" ] && [ "$SUBCOM" == "policies" ];then
	curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/policies" | jq '.' #'.[]'
elif [ "$MAINCOM" == "iam" ] && [ "$SUBCOM" == "groups" ];then
	curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/groups" | jq '.' #'.[]'
# End of unsupported APIs
elif [ "$MAINCOM" == "iam" ] && [ "$SUBCOM" == "projects" ];then
	curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/projects" | jq '.' #'.[]'
elif [ "$MAINCOM" == "iam" -a "$SUBCOM" == "project" ] ||
     [ "$MAINCOM" == "iam" -a "$SUBCOM" == "tenant" ]; then
	echo $OS_PROJECT_ID
elif [ "$MAINCOM" == "iam" -a "$SUBCOM" == "listidp" ]; then
	curlgetauth "$TOKEN" "${IAM_AUTH_URL%/auth*}/OS-FEDERATION/identity_providers" | jq -r 'def str(v): v|tostring; .identity_providers[] | .id+"   "+str(.enabled)+"   "+.links.self+"   "+.description'
elif [ "$MAINCOM" == "iam" -a "$SUBCOM" == "showidp" ]; then
	curlgetauth "$TOKEN" "${IAM_AUTH_URL%/auth*}/OS-FEDERATION/identity_providers/$1" | jq -r '.'
elif [ "$MAINCOM" == "iam" -a "$SUBCOM" == "listmapping" ]; then
	curlgetauth "$TOKEN" "${IAM_AUTH_URL%/auth*}/OS-FEDERATION/mappings" | jq -r 'def str(s): s|tostring; .mappings[] | .id+"   "+.links.self+"   "+str(.rules[].local)+"   "+str(.rules[].remote)'
elif [ "$MAINCOM" == "iam" -a "$SUBCOM" == "showmapping" ]; then
	curlgetauth "$TOKEN" "${IAM_AUTH_URL%/auth*}/OS-FEDERATION/mappings/$1" | jq -r '.'
elif [ "$MAINCOM" == "iam" -a "$SUBCOM" == "listprotocol" ]; then
	curlgetauth "$TOKEN" "${IAM_AUTH_URL%/auth*}/OS-FEDERATION/protocols" | jq -r '.protocols[] | .id+"   "+.mapping_id+"   "+.links.self'
elif [ "$MAINCOM" == "iam" -a "$SUBCOM" == "showprotocol" ]; then
	curlgetauth "$TOKEN" "${IAM_AUTH_URL%/auth*}/OS-FEDERATION/protocols/$1" | jq -r '.'
elif [ "$MAINCOM" == "iam" -a "$SUBCOM" == "keystonemeta" ]; then
	curlgetauth "$TOKEN" "${IAM_AUTH_URL%/auth*}-ext/auth/OS-FEDERATION/SSO/metadata"
   echo

elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "volume-list" ] ||
     [ "$MAINCOM" == "evs" -a "$SUBCOM" == "list" ];then
	getEVSList
elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "volume-details" ] ||
     [ "$MAINCOM" == "evs" -a "$SUBCOM" == "details" ];then
	getEVSListOTC
elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "volume-show" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "describe-volumes" ] ||
     [ "$MAINCOM" == "evs" -a "$SUBCOM" == "show" ];then
	getEVSDetail $1
elif [ "$MAINCOM" == "evs" -a "$SUBCOM" == "create" ]; then
	EVSCreate
	echo "Task ID: $EVSTASKID"
	WaitForTask $EVSTASKID 5
elif [ "$MAINCOM" == "evs" ] && [ "$SUBCOM" == "delete" ];then
	EVSDelete "$@"
	echo "Task ID: $EVSTASKID"
	WaitForTask $EVSTASKID 5
elif [ "$MAINCOM" == "evs" -a "$SUBCOM" == "attach" ]; then
	if [ "$1" = -n ] || [ "$1" = --name ]
	then
		ECSAttachVolumeName "$2" "$3"
	else
		ECSAttachVolumeId   "$1" "$2"
	fi
elif [ "$MAINCOM" == "evs" -a "$SUBCOM" == "detach" ]; then
	if [ "$1" = -n ] || [ "$1" = --name ]
	then
		ECSDetachVolumeName "$2" "$3"
	else
		ECSDetachVolumeId   "$1" "$2"
	fi

elif [ "$MAINCOM" == "backuppolicy" -a "$SUBCOM" == "list" ]; then
	getBackupPolicyList
elif [ "$MAINCOM" == "backuppolicy" -a "$SUBCOM" == "show" ]; then
	getBackupPolicyDetail "$1"
elif [ "$MAINCOM" == "backup" -a "$SUBCOM" == "list" ]; then
	getBackupList
elif [ "$MAINCOM" == "backup" -a "$SUBCOM" == "show" ]; then
	getBackupDetail "$1"
elif [ "$MAINCOM" == "backup" -a "$SUBCOM" == "delete" ]; then
	deleteBackupOTC "$1"
elif [ "$MAINCOM" == "backup" -a "$SUBCOM" == "delete_" ]; then
	deleteBackup "$1"
elif [ "$MAINCOM" == "backup" -a "$SUBCOM" == "create" ] ||
     [ "$MAINCOM" == "backup" -a "$SUBCOM" == "backup" ] ; then
	createBackup "$@"
elif [ "$MAINCOM" == "backup" -a "$SUBCOM" == "restore" ]; then
	restoreBackup "$@"
elif [ "$MAINCOM" == "snapshot" -a "$SUBCOM" == "list" ]; then
	getSnapshotList
elif [ "$MAINCOM" == "snapshot" -a "$SUBCOM" == "show" ]; then
	getSnapshotDetail "$1"
elif [ "$MAINCOM" == "snapshot" -a "$SUBCOM" == "delete" ]; then
	deleteSnapshot "$1"

elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "list" ]; then
	getELBList
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "show" ]; then
	getELBDetail $1
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "delete" ]; then
	deleteELB $1
	echo "$ELBJOBID"
	WaitForTask $ELBJOBID 2
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "create" ]; then
	createELB "$@"
	echo "$ELBJOBID"
	#WaitForTask $ELBJOBID 2
	WaitForTaskFieldOpt $ELBJOBID .entities.elb.id

elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "listlistener" ]; then
	getListenerList "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "showlistener" ]; then
	getListenerDetail "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "createlistener" ] ||
     [ "$MAINCOM" == "elb" -a "$SUBCOM" == "addlistener" ]; then
	createListener "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "dellistener" ]; then
	deleteListener "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "listmember" ]; then
	getMemberList "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "showmember" ]; then
	getMemberDetail "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "addmember" ]; then
	createMember "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "delmember" ]; then
	deleteMember "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "showcheck" ]; then
	getCheck "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "addcheck" ]; then
	createCheck "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "delcheck" ]; then
	deleteCheck "$@"

elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "list" ] ||
     [ "$MAINCOM" == "rds" -a "$SUBCOM" == "listinstances" ]; then
	getRDSInstanceList
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "show" ] ||
     [ "$MAINCOM" == "rds" -a "$SUBCOM" == "showinstances" ]; then
	getRDSInstanceDetails "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "apis" ] ||
     [ "$MAINCOM" == "rds" -a "$SUBCOM" == "listapis" ]; then
	getRDSAPIVersionList
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "showapi" ]; then
	getRDSAPIDetails "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "datastore" ] ||
     [ "$MAINCOM" == "rds" -a "$SUBCOM" == "showdatastore" ]; then
	getRDSDatastoreDetails "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "showdatastoreparameters" ]; then
	getRDSDatastoreParameters "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "showdatastoreparameter" ]; then
	getRDSDatastoreParameter "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "flavors" ] ||
     [ "$MAINCOM" == "rds" -a "$SUBCOM" == "listflavors" ]; then
	getRDSFlavorList "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "showflavor" ]; then
	getRDSFlavorDetails "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "create" ]; then
	createRDSInstance "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "delete" ]; then
	deleteRDSInstance "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "showbackuppolicy" ]; then
	getRDSInstanceBackupPolicy "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "listsnapshots" ] ||
     [ "$MAINCOM" == "rds" -a "$SUBCOM" == "listbackups" ]; then
	getRDSSnapshots
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "showerrors" ]; then
	getRDSErrorLogs "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "showslowstatements" ] ||
     [ "$MAINCOM" == "rds" -a "$SUBCOM" == "showslowqueries" ]; then
	getRDSSlowStatementLogs "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "createsnapshot" ] ||
     [ "$MAINCOM" == "rds" -a "$SUBCOM" == "createbackup" ]; then
	createRDSSnapshot "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "deletesnapshot" ] ||
     [ "$MAINCOM" == "rds" -a "$SUBCOM" == "deletebackup" ]; then
	deleteRDSSnapshot "$@"

elif [ "$MAINCOM" == "domain" -a "$SUBCOM" == "list" ]; then
	listDomains
elif [ "$MAINCOM" == "domain" -a "$SUBCOM" == "create" ]; then
	createDomain "$@"
elif [ "$MAINCOM" == "domain" -a "$SUBCOM" == "show" ]; then
	showDomain "$1"
elif [ "$MAINCOM" == "domain" -a "$SUBCOM" == "delete" ]; then
	deleteDomain "$1"
elif [ "$MAINCOM" == "domain" -a "$SUBCOM" == "listrecords" ]; then
	listRecords "$1"
elif [ "$MAINCOM" == "domain" -a "$SUBCOM" == "showrecord" ]; then
	showRecord "$@"
elif [ "$MAINCOM" == "domain" -a "$SUBCOM" == "delrecord" ]; then
	deleteRecord "$@"
elif [ "$MAINCOM" == "domain" -a "$SUBCOM" == "addrecord" ]; then
	addRecord "$@"

elif [ "$MAINCOM" == "cluster" -a "$SUBCOM" == "list" ]; then
	shortlistClusters
elif [ "$MAINCOM" == "cluster" -a "$SUBCOM" == "list-detail" ] ||
     [ "$MAINCOM" == "cluster" -a "$SUBCOM" == "details" ]; then
	listClusters
elif [ "$MAINCOM" == "cluster" -a "$SUBCOM" == "show" ]; then
	showCluster "$@"
elif [ "$MAINCOM" == "host" -a "$SUBCOM" == "list" ]; then
	listClusterHosts "$@"
elif [ "$MAINCOM" == "host" -a "$SUBCOM" == "show" ]; then
	showClusterHost "$@"

elif [ "$MAINCOM" == "metrics" -a "$SUBCOM" == "list" ]; then
	listMetrics "$@"
elif [ "$MAINCOM" == "metrics" -a "$SUBCOM" == "favorites" ]; then
	listFavMetrics
elif [ "$MAINCOM" == "metrics" -a "$SUBCOM" == "show" ]; then
	showMetrics "$@"
elif [ "$MAINCOM" == "alarms" -a "$SUBCOM" == "list" ]; then
	listAlarms
elif [ "$MAINCOM" == "alarms" -a "$SUBCOM" == "show" ]; then
	showAlarms "$1"
elif [ "$MAINCOM" == "alarms" -a "$SUBCOM" == "limits" ]; then
	showAlarmsQuotas
elif [ "$MAINCOM" == "alarms" -a "$SUBCOM" == "disable" ]; then
	AlarmsAction "false" "$1"
elif [ "$MAINCOM" == "alarms" -a "$SUBCOM" == "enable" ]; then
	AlarmsAction "true" "$1"
elif [ "$MAINCOM" == "alarms" -a "$SUBCOM" == "delete" ]; then
	deleteAlarms "$1"

elif [ "$MAINCOM" == "trace" -a "$SUBCOM" == "list" ]; then
	listTrackers
elif [ "$MAINCOM" == "queues" -a "$SUBCOM" == "list" ]; then
	listQueues
elif [ "$MAINCOM" == "notifications" -a "$SUBCOM" == "list" ]; then
	listTopics

elif [ "$MAINCOM" == "mds" -a "$SUBCOM" == "meta_data" ]; then
	getMeta meta_data.json "$@"
elif [ "$MAINCOM" == "mds" -a "$SUBCOM" == "vendor_data" ]; then
	getMeta vendor_data.json "$@"
elif [ "$MAINCOM" == "mds" -a "$SUBCOM" == "user_data" ]; then
	getMeta user_data "$@"
elif [ "$MAINCOM" == "mds" -a "$SUBCOM" == "password" ]; then
	getMeta password "$@"

elif [ "$MAINCOM" == "custom" ]; then
   handleCustom "$SUBCOM" "$@"

else
	printHelp
fi
