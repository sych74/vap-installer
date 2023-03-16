#!/bin/bash

OPENSTACK="/opt/jelastic-python311/bin/openstack --insecure"

SUCCESS_CODE=0
VALIDATION_ERROR_CODE=100
FAIL_CODE=99

BASE_DIR="$(pwd)"

RUN_LOG="$BASE_DIR/installer.log"
VAP_ENVS="$BASE_DIR/.vapenv"
FLAVORS_JSON="$BASE_DIR/flavors.json"
INFRA_FLAVORS_JSON="$BASE_DIR/infraFlavors.json"
USER_FLAVORS_JSON="$BASE_DIR/userFlavors.json"
IMAGES_JSON="$BASE_DIR/images.json"
SUBNETS_JSON="$BASE_DIR/subnets.json"

###For production
#MIN_INFRA_VCPU=8
#MIN_INFRA_RAM=32000
#MIN_USER_VCPU=12
#MIN_USER_RAM=48000

### For testing
MIN_INFRA_VCPU=1
MIN_INFRA_RAM=1
MIN_USER_VCPU=1
MIN_USER_RAM=4

[[ -f "/var/log/installer.log" ]] && RUN_LOG="/var/log/installer.log"

log(){
  local message=$1
  local timestamp
  timestamp=`date "+%Y-%m-%d %H:%M:%S"`
  echo -e "[${timestamp}]: ${message}" >> ${RUN_LOG}
}

execResponse(){
  local result=$1
  local message=$2
  local output_json="{\"result\": ${result}, \"out\": \"${message}\"}"
  echo $output_json
}

execAction(){
  local action="$1"
  local message="$2"
  source ${VAP_ENVS}
  stdout=$( { ${action}; } 2>&1 ) && { log "${message}...done";  } || {
    log "${message}...failed\n${stdout}\n";
    responseValidate "${stdout}";
  }
}

execReturn(){
  local action="$1"
  local message="$2"
  source ${VAP_ENVS}
  stdout=$( { ${action}; } 2>&1 ) && { log "${message}...done"; echo ${stdout}; } || {
    log "${message}...failed\n${stdout}\n";
    responseValidate "${stdout}";
  }
}

getFlavors(){
  local cmd="${OPENSTACK} flavor list -f json"
  local output=$(execReturn "${cmd}" "Getting flavors list")
  echo $output > $FLAVORS_JSON
}

getFlavorsByParam(){
  local name="$1"
  local min_cpu="$2"
  local min_ram="$3"
  local title="$4"
  local id=0
  local flavors=$(cat $FLAVORS_JSON)
  local infra_flavors=$(jq -n '[]')

  for flavor in $(echo "${flavors}" | jq -r '.[] | @base64'); do
    _jq() {
     echo "${flavor}" | base64 --decode | jq -r "${1}"
    }
    RAM=$(_jq '.RAM')
    VCPUs=$(_jq '.VCPUs')

    [[ $RAM -ge $min_ram  && $VCPUs -ge $min_cpu  ]] && {

      id=$((id+1))
      Name=$(_jq '.Name')
      Ephemeral=$(_jq '.Ephemeral')

      infra_flavors=$(echo $infra_flavors | jq \
        --argjson id $id \
        --arg Name "$Name" \
        --arg RAM  $RAM \
        --arg VCPUs  $VCPUs \
        --arg Ephemeral  "$Ephemeral" \
      '. += [{"id": $id, "Name": $Name, "RAM": $RAM, "VCPUs": $VCPUs, "Ephemeral": $Ephemeral}]')
    }
  done

  local output="{\"result\": 0, \"flavors\": ${infra_flavors}}"
  echo $infra_flavors > ${name}

  if [[ "x${FORMAT}" == "xjson" ]]; then
    log "Creating ${title}...done";
  else
    seperator=---------------------------------------------------------------------------------------------------
    rows="%-5s| %-20s| %-20s| %-20s| %s\n"
    TableWidth=100
    echo -e "\n\n${title}"
    printf "%.${TableWidth}s\n" "$seperator"
    printf "%-5s| %-20s| %-20s| %-20s| %s\n" ID Name RAM VCPUs Ephemeral
    printf "%.${TableWidth}s\n" "$seperator"

    for row in $(echo "${infra_flavors}" | jq -r '.[] | @base64'); do
      _jq() {
        echo "${row}" | base64 --decode | jq -r "${1}"
      }
      id=$(_jq '.id')
      Name=$(_jq '.Name')
      RAM=$(_jq '.RAM')
      VCPUs=$(_jq '.VCPUs')
      Ephemeral=$(_jq '.Ephemeral')
      printf "$rows" "$id" "$Name" "$RAM" "$VCPUs" "$Ephemeral"
    done
  fi

}

getInfraFlavors(){
  getFlavorsByParam "${INFRA_FLAVORS_JSON}" "${MIN_INFRA_VCPU}" "${MIN_INFRA_RAM}" "Infra node flavors"
}

getUserFlavors(){
  getFlavorsByParam "${USER_FLAVORS_JSON}" "${MIN_USER_VCPU}" "${MIN_USER_RAM}" "User node flavors"
}

getImages(){
  local id=0
  local images=$(jq -n '[]')
  local cmd="${OPENSTACK} image list -f json"
  local full_images=$(execReturn "${cmd}" "Getting images list")

  source ${VAP_ENVS}

  for row in $(echo "${full_images}" | jq -r '.[] | @base64'); do
    _jq() {
     echo "${row}" | base64 --decode | jq -r "${1}"
    }
    Name=$(_jq '.Name')

    grep -qE "^vap-[0-9]{2}-[0-9]" <<< ${Name} && {
      id=$((id+1))
      Status=$(_jq '.Status')

      images=$(echo $images | jq \
        --argjson id "$id" \
        --arg Name "$Name" \
        --arg Status  "$Status" \
      '. += [{"id": $id, "Name": $Name, "Status": $Status}]')
    }
  done

  local output="{\"result\": 0, \"images\": ${images}}"
  echo $images > ${IMAGES_JSON}

  if [[ "x${FORMAT}" == "xjson" ]]; then
    log "Validation images...done";
  else
    seperator=---------------------------------------------------------------------------------------------------
    rows="%-5s| %-50s| %s\n"
    TableWidth=100
    echo -e "\n\nVHI Images List"
    printf "%.${TableWidth}s\n" "$seperator"
    printf "%-5s| %-50s| %s\n" ID Name Status
    printf "%.${TableWidth}s\n" "$seperator"

    for row in $(echo "${images}" | jq -r '.[] | @base64'); do
      _jq() {
        echo "${row}" | base64 --decode | jq -r "${1}"
      }
      id=$(_jq '.id')
      Name=$(_jq '.Name')
      Status=$(_jq '.Status')
      printf "$rows" "$id" "$Name" "$Status"
    done
  fi

}

getSubnets(){
  local id=0
  local subnets=$(jq -n '[]')
  source ${VAP_ENVS}
  for i in $(${OPENSTACK} network list -f value -c Name); do
    [[ "$(${OPENSTACK} network show $i -f value -c provider:network_type)" == "flat" ]] && {
      for subnet in $(${OPENSTACK} network show $i -f json -c subnets | jq -r .subnets[]); do
        detail_subnet="$(${OPENSTACK} subnet show $subnet -f json)"
        subnet_name="$(echo $detail_subnet | jq -r .name)"
        cidr="$(echo $detail_subnet | jq -r .cidr)"
        grep -qE "(^127\.)|(^10\.)|(^172\.1[6-9]\.)|(^172\.2[0-9]\.)|(^172\.3[0-1]\.)|(^192\.168\.)|(^169\.254)" <<< $cidr || {
          id=$((id+1))
          subnets=$(echo $subnets | jq \
            --argjson id "$id" \
            --arg Name "$subnet_name" \
            --arg Network "$subnet" \
            --arg Subnet "$cidr" \
          '. += [{"id": $id, "Name": $Name, "Network": $Network, "Subnet": $Subnet}]')
        }
      done
    }
  done

  local output="{\"result\": 0, \"subnets\": ${subnets}}"
  echo $subnets > ${SUBNETS_JSON}

  if [[ "x${FORMAT}" == "xjson" ]]; then
    log "Getting subnets...done";
  else
    seperator=---------------------------------------------------------------------------------------------------
    rows="%-5s| %-20s| %-50s| %s\n"
    TableWidth=100
    echo -e "\n\nVHI Cluster Subnets"
    printf "%.${TableWidth}s\n" "$seperator"
    printf "%-5s| %-20s| %-50s| %s\n" ID Name Network Subnet
    printf "%.${TableWidth}s\n" "$seperator"

    for row in $(echo "${subnets}" | jq -r '.[] | @base64'); do
      _jq() {
        echo "${row}" | base64 --decode | jq -r "${1}"
      }
      id=$(_jq '.id')
      Name=$(_jq '.Name')
      Network=$(_jq '.Network')
      Subnet=$(_jq '.Subnet')
      printf "$rows" "$id" "$Name" "$Network" "$Subnet"
    done
  fi
}

getWebinstallerLink(){
  local stack_name="$1"
  local cmd="${OPENSTACK} stack output show ${stack_name} webinstaller_link -f value -c output_value "
  local output=$(execReturn "${cmd}" "Getting webinstaller_link for ${stack_name} stack")
  echo $output
}

responseValidate(){
  local response="$1"
  local errorsArray="HTTP 401:Your credentials are incorrect or have expired,"
  errorsArray+="HTTP 404:API version is incorrect,"
  errorsArray+="Name or service not known:API endpoint URL is invalid"

  while read -d, -r pair; do
    IFS=':' read -r key val <<<"$pair"
    grep -q "$key" <<< "$response" && {
      [[ "x${FORMAT}" == "xjson" ]] && { execResponse "${VALIDATION_ERROR_CODE}" "$val"; exit 0; } || { echo "$val"; exit 0; };
    }
  done <<<"$errorsArray,"
  [[ "x${FORMAT}" == "xjson" ]] && { execResponse "${FAIL_CODE}" "Please check the ${RUN_LOG} log file for details."; exit 0; } || { echo "$response"; exit 0; };
}

configure(){
  for i in "$@"; do
    case $i in
      --project-domain=*)
      PROJECT_DOMAIN=${i#*=}
      shift
      shift
      ;;
      --user-domain=*)
      USER_DOMAIN=${i#*=}
      shift
      shift
      ;;
      --project=*)
      PROJECT=${i#*=}
      shift
      shift
      ;;
      --username=*)
      USERNAME=${i#*=}
      shift
      shift
      ;;
      --password=*)
      PASSWORD=${i#*=}
      shift
      shift
      ;;
      --url=*)
      URL=${i#*=}
      shift
      shift
      ;;
      --vap-stack-name=*)
      VAP_STACK_NAME=${i#*=}
      shift
      shift
      ;;
      --format=*)
      FORMAT=${i#*=}
      shift
      shift
      ;;

      *)
        ;;
    esac
  done

  if [ -z "${PROJECT_DOMAIN}" ] || [ -z "${USER_DOMAIN}" ] || \
     [ -z "${PROJECT}" ] ||  [ -z "${USERNAME}" ] || \
     [ -z "${PASSWORD}" ] ||  [ -z "${URL}" ] || \
     [ -z "${VAP_STACK_NAME}" ]; then

      echo "Not all arguments passed!"
      usage
      exit 1;

  fi

  echo "export OS_PROJECT_DOMAIN_NAME=${PROJECT_DOMAIN}" > ${VAP_ENVS};
  echo "export OS_USER_DOMAIN_NAME=${USER_DOMAIN}" >> ${VAP_ENVS};
  echo "export OS_PROJECT_NAME=${PROJECT}" >> ${VAP_ENVS};
  echo "export OS_USERNAME=${USERNAME}" >> ${VAP_ENVS};
  echo "export OS_PASSWORD=${PASSWORD}" >> ${VAP_ENVS};
  echo "export OS_AUTH_URL=${URL}" >> ${VAP_ENVS};
  echo "export OS_IDENTITY_API_VERSION=3" >> ${VAP_ENVS};
  echo "export OS_AUTH_TYPE=password" >> ${VAP_ENVS};
  echo "export OS_INSECURE=true" >> ${VAP_ENVS};
  echo "export NOVACLIENT_INSECURE=true" >> ${VAP_ENVS};
  echo "export NEUTRONCLIENT_INSECURE=true" >> ${VAP_ENVS};
  echo "export CINDERCLIENT_INSECURE=true" >> ${VAP_ENVS};
  echo "export OS_PLACEMENT_API_VERSION=1.22" >> ${VAP_ENVS};
  echo "export VAP_STACK_NAME=${VAP_STACK_NAME}" >> ${VAP_ENVS};
  [[ "x${FORMAT}" == "xjson" ]] && { echo "export FORMAT=${FORMAT}" >> ${VAP_ENVS}; }

  execAction "${OPENSTACK} stack list" "Parameters validation"
  for stack in $(source ${VAP_ENVS};  ${OPENSTACK} stack list -f value -c 'Stack Name'); do
    grep -q "$stack" <<< "$VAP_STACK_NAME" && {
      [[ "x${FORMAT}" == "xjson" ]] && {
        execResponse "${VALIDATION_ERROR_CODE}" "Stack name $VAP_STACK_NAME is already taken"; exit 0;
      } || {
        echo "Stack name $VAP_STACK_NAME is already taken"; exit 0;
      };
    }
  done

  getFlavors
  getInfraFlavors
  getUserFlavors
  getSubnets
  getImages

  [[ "x${FORMAT}" == "xjson" ]] && { execResponse "${SUCCESS_CODE}" "Сonfigured successfully"; }

}

create(){
  for i in "$@"; do
    case $i in
      --image=*)
      IMAGE=${i#*=}
      shift
      shift
      ;;
      --user-host-count=*)
      USER_HOST_COUNT=${i#*=}
      shift
      shift
      ;;
      --subnet=*)
      SUBNET=${i#*=}
      shift
      shift
      ;;
      --user-flavor=*)
      USER_FLAVOR=${i#*=}
      shift
      shift
      ;;
      --infra-flavor=*)
      INFRA_FLAVOR=${i#*=}
      shift
      shift
      ;;
      --infra-root-size=*)
      INFRA_ROOT_SIZE=${i#*=}
      shift
      shift
      ;;
      --user-root-size=*)
      USER_ROOT_SIZE=${i#*=}
      shift
      shift
      ;;
      --infra-vz-size=*)
      INFRA_VZ_SIZE=${i#*=}
      shift
      shift
      ;;
      --user-vz-size=*)
      USER_VZ_SIZE=${i#*=}
      shift
      shift
      ;;
      *)
        ;;
    esac
  done

  if [ -z "${IMAGE}" ] || [ -z "${USER_HOST_COUNT}" ] || \
     [ -z "${SUBNET}" ] ||  [ -z "${USER_FLAVOR}" ] || \
     [ -z "${INFRA_FLAVOR}" ] ||  [ -z "${INFRA_ROOT_SIZE}" ] || \
     [ -z "${USER_ROOT_SIZE}" ] ||  [ -z "${INFRA_VZ_SIZE}" ] || [ -z "${USER_VZ_SIZE}" ]; then

      echo "Not all arguments passed!"
      usage
      exit 1;

  fi

  _getValueById(){
    local id="$1"
    local arg="$2"
    local json_name="$3"
    local result=$(jq ".[] | select(.id == ${id}) | .${arg}" ${json_name} | tr -d '"')
    echo $result
  }

  source ${VAP_ENVS}
  IMAGE=$(_getValueById $IMAGE "Name" "images.json")
  SUBNET=$(_getValueById $SUBNET "Name" "subnets.json")
  INFRA_FLAVOR=$(_getValueById $INFRA_FLAVOR "Name" "infraFlavors.json")
  USER_FLAVOR=$(_getValueById $USER_FLAVOR "Name" "userFlavors.json")

  local createcmd="${OPENSTACK} stack create ${VAP_STACK_NAME} -t VAP.yaml"
  createcmd+=" --parameter image=${IMAGE}"
  createcmd+=" --parameter user_hosts_count=${USER_HOST_COUNT}"
  createcmd+=" --parameter public_network=public"
  createcmd+=" --parameter public_subnet=${SUBNET}"
  createcmd+=" --parameter infra_flavor=${INFRA_FLAVOR}"
  createcmd+=" --parameter user_flavor=${USER_FLAVOR}"
  createcmd+=" --parameter infra_root_volume_size=${INFRA_ROOT_SIZE}"
  createcmd+=" --parameter user_root_volume_size=${USER_ROOT_SIZE}"
  createcmd+=" --parameter infra_vz_volume_size=${INFRA_VZ_SIZE}"
  createcmd+=" --parameter user_vz_volume_size=${USER_VZ_SIZE}"
  createcmd+=" --parameter infra_swap_volume_size=8"
  createcmd+=" --parameter user_swap_volume_size=8"
  createcmd+=" --parameter key_name=vap-installer-demo"
  createcmd+=" --wait"

  [[ "x${FORMAT}" == "xjson" ]] && { execAction "${createcmd}" "Creating new stack" ; } || { ${createcmd} ; };

  web_link=$(getWebinstallerLink ${VAP_STACK_NAME})

  [[ "x${FORMAT}" == "xjson" ]] && { execResponse "${SUCCESS_CODE}" "Web Installer Link: $web_link"; } || { echo "Web Installer Link: $web_link"; };

}

usage() {
SCRIPTNAME=$(basename "$BASH_SOURCE")
echo " USAGE:"
echo "   CONFIGURE VHI CLUSTER DETAILS:"
echo "       COMMAND:  "
echo "             $SCRIPTNAME configure --project-domain=[PROJECT_DOMAIN] --user-domain=[USER_DOMAIN] --project=[PROJECT] --username=[USERNAME] --password=[PASSWORD] --url=[URL] --vap-stack-name=[STACK NAME] "
echo "       ARGUMENTS:    "
echo "             --project-domain - VHI cluster project name the user account belongs to"
echo "             --user-domain - VHI cluster project name the user account belongs to"
echo "             --project - VHI cluster project name the user account belongs to"
echo "             --username - VHI cluster account username"
echo "             --password - VHI cluster account password"
echo "             --url - VHI cluster API endpoint URL"
echo "             --vap-stack-name - Specify VHI cluster API endpoint URL"
echo
echo "        NOTICE:"
echo "              - notice1."
echo "                notice2."
echo "                notice3"
echo
echo "   CREATE NEW VAP:"
echo "       COMMAND:  "
echo "             $SCRIPTNAME create --infra-flavor=1 --user-flavor=1 --subnet=1 --image=2 --user-host-count=1 --infra-root-size=100 --infra-vz-size=400 --user-root-size=100 --user-vz-size=800 "
echo "       ARGUMENTS:    "
echo "             --infra-flavor - ID of nfra node flavor "
echo "             --user-flavor - ID of User node flavor"
echo "             --subnet - ID of public subnet"
echo "             --image - ID of VAP image available on VHI cluster"
echo "             --user-host-count - Number of user host nodes to be created"
echo "             --infra-root-size - Infra node storage volume size in GB"
echo "             --infra-vz-size - Infra node storage volume size in GB"
echo "             --user-root-size - User node storage volume size in GB"
echo "             --user-vz-size - User node  storage volume size in GB"
echo
echo "        NOTICE:"
echo "              - notice1."
echo "                notice2."
echo "                notice3"
echo
}

case ${1} in
    configure)
      configure "$@"
      ;;

    create)
      create "$@"
      ;;
    *)
      echo "Please use $(basename "$BASH_SOURCE") configure or $(basename "$BASH_SOURCE") create"
      usage
esac
