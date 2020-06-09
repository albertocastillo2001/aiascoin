#!/bin/bash

TMP_FOLDER=$(mktemp -d) 

DAEMON_ARCHIVE_URL=${1:-"https://github.com/AIAScoinTechnologies/aiascoin/releases/download/1.2.9/aias129-linux-x86_64.zip"}
BLOCKCHAIN_SNAPSHOT_URL=${1:-"https://github.com/AIAScoinTechnologies/bootstrap/releases/download/v1.0/blockchain.zip"}
ARCHIVE_STRIP=""
DEFAULT_PORT=10721

COIN_NAME="aias"
CONFIG_FILE="${COIN_NAME}.conf"
DEFAULT_USER_NAME="${COIN_NAME}-mn1"
DAEMON_FILE="${COIN_NAME}d"
CLI_FILE="${COIN_NAME}-cli"

BINARIES_PATH=/usr/local/bin
DAEMON_PATH="${BINARIES_PATH}/${DAEMON_FILE}"
CLI_PATH="${BINARIES_PATH}/${CLI_FILE}"

DONATION_ADDRESS_CLICK2INSTALL="AJvfhEfJX5wvhxU4XoHGiFsCbyF1Cnuydq"
DONATION_ADDRESS_ALB2001="AJFBkUrqHsu8qwQidYLAjS8j5xMnTa6QYB"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

function checks() 
{
  if [[ $(lsb_release -d) != *16.04* ]] || [[ $(lsb_release -d) != *18.04* ]]; then
    echo -e " ${RED}You are not running Ubuntu 16.04 or 18.04. Installation is cancelled.${NC}"
    exit 1
  fi

  if [[ $EUID -ne 0 ]]; then
     echo -e " ${RED}$0 must be run as root so it can update your system and create the required masternode users.${NC}"
     exit 1
  fi

  if [ -n "$(pidof ${DAEMON_FILE})" ]; then
    read -e -p " $(echo -e The ${COIN_NAME} daemon is already running.${YELLOW} Do you want to add another master node? [Y/N] $NC)" NEW_NODE
    clear
  else
    NEW_NODE="new"
  fi
}

function prepare_system() 
{
  clear
  echo -e "Checking if swap space is required."
  local PHYMEM=$(free -g | awk '/^Mem:/{print $2}')
  
  if [ "${PHYMEM}" -lt "2" ]; then
    local SWAP=$(swapon -s get 1 | awk '{print $1}')
    if [ -z "${SWAP}" ]; then
      echo -e "${GREEN}Server is running without a swap file and has less than 2G of RAM, creating a 2G swap file.${NC}"
      dd if=/dev/zero of=/swapfile bs=1024 count=2M
      chmod 600 /swapfile
      mkswap /swapfile
      swapon -a /swapfile
      echo "/swapfile    none    swap    sw    0   0" >> /etc/fstab
    else
      echo -e "${GREEN}Swap file already exists.${NC}"
    fi
  else
    echo -e "${GREEN}Server running with at least 2G of RAM, no swap file needed.${NC}"
  fi
  
  echo -e "${GREEN}Updating package manager.${NC}"
  apt update
  
  echo -e "${GREEN}Upgrading existing packages, it may take some time to finish.${NC}"
  DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y -qq upgrade 
  
  echo -e "${GREEN}Installing all dependencies for the ${COIN_NAME} coin master node, it may take some time to finish.${NC}"
  apt install -y software-properties-common
  apt-add-repository -y ppa:bitcoin/bitcoin
  apt update
  apt install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    automake \
    bsdmainutils \
    build-essential \
    curl \
    git \
    htop \
    libboost-chrono-dev \
    libboost-dev \
    libboost-filesystem-dev \
    libboost-program-options-dev \
    libboost-system-dev \
    libboost-test-dev \
    libboost-thread-dev \
    libdb4.8-dev \
    libdb4.8++-dev \
    libdb5.3++ \
    libevent-dev \
    libgmp3-dev \
    libminiupnpc-dev \
    libssl-dev \
    libtool \
    autoconf \
    libzmq5 \
    make \
    net-tools \
    pkg-config \
    pwgen \
    software-properties-common \
	  tar \
    ufw \
    unzip \
    wget
  clear
}

function deploy_binary() 
{
  if [ -f ${DAEMON_PATH} ]; then
    echo -e " ${GREEN}${COIN_NAME} daemon binary file already exists, using binary from ${DAEMON_PATH}.${NC}"
  else
    cd ${TMP_FOLDER}

    local archive=${COIN_NAME}.tar.gz
    echo -e " ${GREEN}Downloading binaries and deploying the ${COIN_NAME} service.${NC}"
    local daemon_archive=$(echo ${DAEMON_ARCHIVE_URL} | awk -F "/" '{print $(NF-0)}')

    wget ${DAEMON_ARCHIVE_URL}
    unzip ${daemon_archive} ${DAEMON_FILE} ${CLI_FILE} -d ${BINARIES_PATH}

    chmod +x ${DAEMON_PATH} >/dev/null 2>&1
    chmod +x ${CLI_PATH} >/dev/null 2>&1
    cd

    rm -rf ${TMP_FOLDER}
  fi
}

function enable_firewall() 
{
  echo -e " ${GREEN}Installing fail2ban and setting up firewall to allow access on port ${PORT}.${NC}"

  apt install ufw -y >/dev/null 2>&1

  ufw disable >/dev/null 2>&1
  ufw allow ${PORT}/tcp comment "${COIN_NAME} Masternode port" >/dev/null 2>&1

  ufw allow 22/tcp comment "SSH port" >/dev/null 2>&1
  ufw limit 22/tcp >/dev/null 2>&1
  
  ufw logging on >/dev/null 2>&1
  ufw default deny incoming >/dev/null 2>&1
  ufw default allow outgoing >/dev/null 2>&1

  echo "y" | ufw enable >/dev/null 2>&1
  systemctl enable fail2ban >/dev/null 2>&1
  systemctl start fail2ban >/dev/null 2>&1
}

function add_daemon_service() 
{
  cat << EOF > /etc/systemd/system/${USER_NAME}.service
[Unit]
Description=${COIN_NAME} masternode daemon service
After=network.target
After=syslog.target
[Service]
Type=forking
User=${USER_NAME}
Group=${USER_NAME}
WorkingDirectory=${HOME_FOLDER}
ExecStart=${DAEMON_PATH} -datadir=${HOME_FOLDER} -conf=${HOME_FOLDER}/$CONFIG_FILE -daemon 
ExecStop=${CLI_PATH} stop
Restart=always
RestartSec=3
PrivateTmp=true
TimeoutStopSec=60s
TimeoutStartSec=10s
StartLimitInterval=120s
StartLimitBurst=5
  
[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  sleep 3

  echo -e " ${GREEN}Starting the ${COIN_NAME} service from ${DAEMON_PATH} on port ${PORT}.${NC}"
  systemctl start ${USER_NAME}.service >/dev/null 2>&1
  
  echo -e " ${GREEN}Enabling the service to start on reboot.${NC}"
  systemctl enable ${USER_NAME}.service >/dev/null 2>&1

  if [[ -z $(pidof $DAEMON_FILE) ]]; then
    echo -e "${RED}The ${COIN_NAME} masternode service is not running${NC}. You should start by running the following commands as root:"
    echo "systemctl start ${USER_NAME}.service"
    echo "systemctl status ${USER_NAME}.service"
    echo "less /var/log/syslog"
    exit 1
  fi
}

function ask_port() 
{
  read -e -p "$(echo -e $YELLOW Enter a port to run the ${COIN_NAME} service on: $NC)" -i ${DEFAULT_PORT} PORT
}

function ask_user() 
{  
  read -e -p "$(echo -e $YELLOW Enter a new username to run the ${COIN_NAME} service as: $NC)" -i ${DEFAULT_USER_NAME} USER_NAME

  if [ -z "$(getent passwd ${USER_NAME})" ]; then
    useradd -m -s "/bin/bash" ${USER_NAME}
    USERPASS=$(pwgen -s 12 1)
    echo "${USER_NAME}:${USERPASS}" | chpasswd

    local home=$(sudo -H -u ${USER_NAME} bash -c 'echo ${HOME}')
    HOME_FOLDER="${home}/.${COIN_NAME}"
        
    mkdir -p ${HOME_FOLDER}
    chown -R ${USER_NAME}: ${HOME_FOLDER} >/dev/null 2>&1
  else
    clear
    echo -e "${RED}User already exists. Please enter another username.${NC}"
    ask_user
  fi
}

function check_port() 
{
  declare -a PORTS

  PORTS=($(netstat -tnlp | awk '/LISTEN/ {print $4}' | awk -F":" '{print $NF}' | sort | uniq | tr '\r\n'  ' '))
  ask_port

  while [[ ${PORTS[@]} =~ ${PORT} ]] || [[ ${PORTS[@]} =~ $[PORT+1] ]]; do
    clear
    echo -e "${RED}Port in use, please choose another port:${NF}"
    ask_port
  done
}

function ask_ip() 
{
  declare -a NODE_IPS
  declare -a NODE_IPS_STR

  for ips in $(netstat -i | awk '!/Kernel|Iface|lo/ {print $1," "}')
  do
    ipv4=$(curl --interface ${ips} --connect-timeout 2 -s4 icanhazip.com)
    NODE_IPS+=(${ipv4})
    NODE_IPS_STR+=("$(echo -e [IPv4] ${ipv4})")

    ipv6=$(curl --interface ${ips} --connect-timeout 2 -s6 icanhazip.com)
    NODE_IPS+=(${ipv6})
    NODE_IPS_STR+=("$(echo -e [IPv6] ${ipv6})")
  done

  if [ ${#NODE_IPS[@]} -gt 1 ]
    then
      echo -e " ${GREEN}More than one IP address found.${NC}"
      INDEX=0
      for ip in "${NODE_IPS_STR[@]}"
      do
        echo -e " [${INDEX}] ${ip}"
        let INDEX=${INDEX}+1
      done
      echo -e " ${YELLOW}Which IP address do you want to use?${NC}"
      read -e choose_ip
      NODEIP=${NODE_IPS[$choose_ip]}
  else
    NODEIP=${NODE_IPS[0]}
  fi
}

function create_config() 
{
  RPCUSER=$(pwgen -s 8 1)
  RPCPASSWORD=$(pwgen -s 15 1)
  cat << EOF > ${HOME_FOLDER}/${CONFIG_FILE}
rpcuser=${RPCUSER}
rpcpassword=${RPCPASSWORD}
rpcallowip=127.0.0.1
rpcport=$[PORT+1]
port=${PORT}
addnode=172.245.110.100
addnode=107.191.40.83
addnode=144.202.106.212
addnode=85.214.41.24
addnode=45.32.76.59
addnode=188.166.90.4
addnode=134.175.134.231:10721
addnode=147.156.56.160:10721
addnode=147.156.56.82:10721
addnode=147.156.56.85:10721
addnode=147.156.56.92:10721
addnode=148.70.227.161:10721
addnode=164.68.96.138:10721
addnode=167.114.242.254:10721
addnode=167.86.115.101:42382
addnode=173.208.132.186:47224
addnode=188.26.150.143:33463
addnode=195.46.0.106:10721
addnode=207.180.213.90:10721
addnode=207.180.244.169:33340
addnode=207.180.244.169:35234
addnode=207.180.244.169:40054
addnode=207.180.244.169:46378
addnode=207.180.244.169:53044
addnode=207.180.244.169:53506
addnode=207.180.244.169:60784
addnode=217.182.89.228:10721
addnode=217.61.124.18:10721
addnode=37.46.245.76:10721
addnode=46.105.34.58:10721
addnode=51.83.108.207:10721
addnode=72.136.83.151:41850
addnode=80.211.94.150:10721
addnode=80.241.214.129:10721
addnode=89.38.149.17:40348
addnode=89.38.149.17:46668
addnode=89.38.149.17:56010
addnode=89.38.149.17:60510
addnode=94.177.235.252:10721
addnode=95.179.140.202:10721
listen=1
server=1
daemon=1
EOF
}

KEY_ATTEMPT=1
function get_key()
{
  echo -e "${GREEN}  Requesting private key${NC}"
  local privkey=$(sudo -u ${USER_NAME} ${CLI_PATH} -datadir=${HOME_FOLDER} -conf=${HOME_FOLDER}/${CONFIG_FILE} masternode genkey 2>&1) 
  
  if [[ -z "${privkey}" ]] || [[ "${privkey^^}" = *"ERROR"* ]]; 
  then
    local retry=5
    echo -e "${GREEN}  - Attempt ${KEY_ATTEMPT}/20: Unable to request private key or node not ready, retrying in ${retry} seconds ...${NC}"
    sleep ${retry}

    KEY_ATTEMPT=$[KEY_ATTEMPT+1]
    if [[ ${KEY_ATTEMPT} -eq 20 ]];
    then
      echo -e "${RED}  - Attempt ${KEY_ATTEMPT}/20: Unable to request a private key from the masternode, installation cannot continue.${NC}"
      exit 1
    else
      get_key
    fi
  else
    echo -e "${GREEN}  - Privkey successfully generated${NC}"
    PRIVKEY=${privkey}
    
    sudo -u ${USER_NAME} ${CLI_PATH} -datadir=${HOME_FOLDER} -conf=${HOME_FOLDER}/${CONFIG_FILE} stop >/dev/null 2>&1
    sleep 5
  fi
}

function download_blockchain()
{
  local blockchain_file="blockchain.zip"
  if [[ ! -f ${blockchain_file} ]];
  then
    read -e -p "$(echo -e ${YELLOW} Do you want to download the blockchain snapshot? [Y/N] ${NC})" CHOICE
    if [[ ("${CHOICE}" == "y" || "${CHOICE}" == "Y") ]]; then
      echo -e "${GREEN}  Downloading blockchain snapshot${NC}"
      wget ${BLOCKCHAIN_SNAPSHOT_URL} -O ${blockchain_file}
      install_blockchain
    fi
  else
    echo -e "${GREEN}  Blockchain snapshot found${NC}"
    install_blockchain
  fi
}

function install_blockchain()
{
  if [[ -f ${blockchain_file} ]];
  then
    echo -e "${GREEN}  Installing blockchain snapshot${NC}"
    rm -rf "${HOME_FOLDER}/blocks" "${HOME_FOLDER}/chainstate" "${HOME_FOLDER}/sporks" "${HOME_FOLDER}/zerocoin"
    unzip -o ${blockchain_file} -d ${HOME_FOLDER}/
    chown -R ${USER_NAME}: ${HOME_FOLDER} >/dev/null 2>&1
  else
    echo -e "${RED}  Error installing blockchain snapshot${NC}"
  fi
}

function create_key() 
{
  read -e -p "$(echo -e ${YELLOW} Paste your masternode private key and press ENTER or leave it blank to generate a new private key. ${NC})" PRIVKEY

  if [[ -z "${PRIVKEY}" ]]; 
  then
    sudo -u ${USER_NAME} ${DAEMON_PATH} -datadir=${HOME_FOLDER} -conf=${HOME_FOLDER}/${CONFIG_FILE} -daemon >/dev/null 2>&1
    sleep 5

    if [[ -z "$(pidof ${DAEMON_FILE})" ]]; 
    then
      echo -e "${RED}${COIN_NAME} deamon couldn't start, could not generate a private key. Check /var/log/syslog for errors.${NC}"
      exit 1
    else
      get_key    
    fi
  fi
}

function update_config() 
{  
  cat << EOF >> ${HOME_FOLDER}/${CONFIG_FILE}
logtimestamps=1
maxconnections=256
masternode=1
externalip=${NODEIP}
masternodeprivkey=${PRIVKEY}
EOF
  chown ${USER_NAME}: ${HOME_FOLDER}/${CONFIG_FILE} >/dev/null
}

function add_log_truncate()
{
  LOG_FILE="${HOME_FOLDER}/debug.log";

  cat << EOF >> /home/${USER_NAME}/logrotate.conf
${HOME_FOLDER}/*.log {
    rotate 4
    weekly
    compress
    missingok
    notifempty
}
EOF

  if ! crontab -l >/dev/null | grep "/home/${USER_NAME}/logrotate.conf"; then
    (crontab -l ; echo "1 0 * * 1 /usr/sbin/logrotate /home/${USER_NAME}/logrotate.conf --state /home/${USER_NAME}/logrotate-state") | crontab -
  fi
}

function show_output() 
{
 echo
 echo -e "================================================================================================================================"
 echo -e "${GREEN}"
 echo -e "                                                 ${COIN_NAME^^} installation completed${NC}"
 echo
 echo -e " Your ${COIN_NAME} coin master node is up and running." 
 echo -e "  - it is running as the ${GREEN}${USER_NAME}${NC} user, listening on port ${GREEN}${PORT}${NC} at your VPS address ${GREEN}${NODEIP}${NC}."
 echo -e "  - the ${GREEN}${USER_NAME}${NC} password is ${GREEN}${USERPASS}${NC}"
 echo -e "  - the ${COIN_NAME} configuration file is located at ${GREEN}${HOME_FOLDER}/${CONFIG_FILE}${NC}"
 echo -e "  - the masternode privkey is ${GREEN}${PRIVKEY}${NC}"
 echo
 echo -e " You can manage your ${COIN_NAME} service from the cmdline with the following commands:"
 echo -e "  - ${GREEN}systemctl start ${USER_NAME}.service${NC} to start the service for the given user."
 echo -e "  - ${GREEN}systemctl stop ${USER_NAME}.service${NC} to stop the service for the given user."
 echo -e "  - ${GREEN}systemctl status ${USER_NAME}.service${NC} to see the service status for the given user."
 echo
 echo -e " The installed service is set to:"
 echo -e "  - auto start when your VPS is rebooted."
 echo -e "  - rotate your ${GREEN}${LOG_FILE}${NC} file once per week and keep the last 4 weeks of logs."
 echo
 echo -e " You can find the masternode status when logged in as ${USER_NAME} using the command below:"
 echo -e "  - ${GREEN}${CLI_FILE} getinfo${NC} to retrieve your nodes status and information"
 echo
 echo -e "   if you are not logged in as ${GREEN}${USER_NAME}${NC} then you can run ${YELLOW}su - ${USER_NAME}${NC} to switch to that user before"
 echo -e "   running the ${GREEN}${CLI_FILE} getinfo${NC} command."
 echo -e "   NOTE: the ${DAEMON_FILE} daemon must be running first before trying this command. See notes above on service commands usage."
 echo
 echo -e " Make sure you keep the information above somewhere private and secure so you can refer back to it." 
 echo -e "${YELLOW} NEVER SHARE YOUR PRIVKEY WITH ANYONE, IF SOMEONE OBTAINS IT THEY CAN STEAL ALL YOUR COINS.${NC}"
 echo
 echo -e "================================================================================================================================"
 echo
 echo
}

function setup_node() 
{
  ask_user
  check_port
  ask_ip
  create_config
  create_key
  download_blockchain
  update_config
  enable_firewall
  add_daemon_service
  add_log_truncate
  show_output
}

clear

echo
echo -e "${GREEN}"
echo -e "============================================================================================================="
echo
echo -e "                                     db    88    db    .dP\"Y8 "
echo -e "                                    dPYb   88   dPYb   \`Ybo."
echo -e "                                   dP__Yb  88  dP__Yb    \`Y8b"  
echo -e "                                  dP\"\"\"\"Yb 88 dP\"\"\"\"Yb 8bodP'" 
echo
echo                          
echo -e "${NC}"
echo -e " This script will automate the installation of your ${COIN_NAME} coin masternode and server configuration by"
echo -e " performing the following steps:"
echo
echo -e "  - Prepare your system with the required dependencies"
echo -e "  - Obtain the latest ${COIN_NAME} masternode files from the ${COIN_NAME} GitHub repository"
echo -e "  - Create a user and password to run the ${COIN_NAME} masternode service"
echo -e "  - Install the ${COIN_NAME} masternode service under the new user [not root]"
echo -e "  - Add DDoS protection using fail2ban"
echo -e "  - Update the system firewall to only allow the masternode port and outgoing connections"
echo -e "  - Rotate and archive the masternode logs to save disk space"
echo
echo -e " You will see ${YELLOW}questions${NC}, ${GREEN}information${NC} and ${RED}errors${NC}. A summary of what has been done will be shown at the end."
echo
echo -e " The files will be downloaded and installed from:"
echo -e " ${GREEN}${DAEMON_ARCHIVE_URL}${NC}"
echo
echo -e " Script created by click2install"
echo -e "  - GitHub: https://github.com/click2install"
echo -e "  - Discord: click2install#0001"
echo -e "  - ${COIN_NAME}: ${DONATION_ADDRESS_CLICK2INSTALL}"
echo
echo -e " Script updated by alb2001"
echo -e "  - GitHub: https://github.com/albertocastillo2001"
echo -e "  - Discord: alb2001#2529"
echo -e "  - ${COIN_NAME}: ${DONATION_ADDRESS_ALB2001}"
echo -e "${GREEN}"
echo -e "============================================================================================================="              
echo -e "${NC}"
read -e -p "$(echo -e ${YELLOW} Do you want to continue? [Y/N] ${NC})" CHOICE

if [[ ("${CHOICE}" == "n" || "${CHOICE}" == "N") ]]; then
  exit 1;
fi

checks

if [[ ("${NEW_NODE}" == "y" || "${NEW_NODE}" == "Y") ]]; then
  setup_node
  exit 0
elif [[ "${NEW_NODE}" == "new" ]]; then
  prepare_system
  deploy_binary
  setup_node
else
  echo -e "${GREEN}${COIN_NAME} daemon already running.${NC}"
  exit 0
fi

