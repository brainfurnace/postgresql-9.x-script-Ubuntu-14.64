#!/bin/bash -e
#Version: 0.5
#MapFig, Inc

apt-get install -y lsb-release
RELEASE=$(lsb_release -cs)
#set below to version
PG_VER='9.4'

touch /root/auth.txt

apt-get clean
apt-get update

UNPRIV_USER='pgadmin'

function install_postgresql(){

	#1. Install PostgreSQL
	echo "deb http://apt.postgresql.org/pub/repos/apt/ ${RELEASE}-pgdg main" > /etc/apt/sources.list.d/pgdg.list
	wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
	apt-get update
	apt-get install -y postgresql-${PG_VER} postgresql-client-${PG_VER} postgresql-contrib-${PG_VER} \
						python3-postgresql postgresql-plperl-${PG_VER} postgresql-plpython-${PG_VER} \
						postgresql-pltcl-${PG_VER} odbc-postgresql libpostgresql-jdbc-java
	if [ ! -f /usr/lib/postgresql/${PG_VER}/bin/postgres ]; then
		echo "Error: Get PostgreSQL version"; exit 1;
	fi

	ln -sf /usr/lib/postgresql/${PG_VER}/bin/pg_config 	/usr/bin
	ln -sf /var/lib/postgresql/${PG_VER}/main/		 	/var/lib/postgresql
	ln -sf /var/lib/postgresql/${PG_VER}/backups		/var/lib/postgresql

	service postgresql start

	#2. Set postgres Password
	if [ $(grep -m 1 -c 'pg pass' /root/auth.txt) -eq 0 ]; then
		PG_PASS=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32);
		sudo -u postgres psql 2>/dev/null -c "alter user postgres with password '${PG_PASS}'"
		echo "pg pass: ${PG_PASS}" > /root/auth.txt
	fi

	#3. Add Postgre variables to environment
	if [ $(grep -m 1 -c 'PGDATA' /etc/environment) -eq 0 ]; then
		cat >>/etc/environment <<CMD_EOF
export PGDATA=/var/lib/postgresql/${PG_VER}/main
CMD_EOF
	fi

	#4. Configure ph_hba.conf
	cat >/etc/postgresql/${PG_VER}/main/pg_hba.conf <<CMD_EOF
local	all all 							md5
host	all all 127.0.0.1	255.255.255.255	md5
host	all all 0.0.0.0/0					md5
host	all all ::1/128						md5
hostssl all all 127.0.0.1	255.255.255.255	md5
hostssl all all 0.0.0.0/0					md5
hostssl all all ::1/128						md5
CMD_EOF
	sed -i.save "s/.*listen_addresses.*/listen_addresses = '*'/" /etc/postgresql/${PG_VER}/main/postgresql.conf
	sed -i.save "s/.*ssl =.*/ssl = on/" /etc/postgresql/${PG_VER}/main/postgresql.conf

	#5. Create Symlinks for Backward Compatibility from PostgreSQL 9 to PostgreSQL 8
	mkdir -p /var/lib/pgsql
	ln -sf /var/lib/postgresql/${PG_VER}/main /var/lib/pgsql
	ln -sf /var/lib/postgresql/${PG_VER}/backups /var/lib/pgsql

	#6. create self-signed SSL certificates
	if [ ! -f /var/lib/postgresql/${PG_VER}/main/server.key -o ! -f /var/lib/postgresql/${PG_VER}/main/server.crt ]; then
		SSL_PASS=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32);
		if [ $(grep -m 1 -c 'ssl pass' /root/auth.txt) -eq 0 ]; then
			echo "ssl pass: ${SSL_PASS}" >> /root/auth.txt
		else
			sed -i.save "s/ssl pass:.*/ssl pass: ${SSL_PASS}/" /root/auth.txt
		fi
		openssl genrsa -des3 -passout pass:${SSL_PASS} -out server.key 1024
		openssl rsa -in server.key -passin pass:${SSL_PASS} -out server.key

		chmod 400 server.key

		openssl req -new -key server.key -days 3650 -out server.crt -passin pass:${SSL_PASS} -x509 -subj '/C=CA/ST=Frankfurt/L=Frankfurt/O=brainfurnace.com/CN=brainfurnace.com/emailAddress=info@brainfurnace.com'
		chown postgres.postgres server.key server.crt
		mv server.key server.crt /var/lib/postgresql/${PG_VER}/main
	fi

	service postgresql restart
}

function install_webmin(){
	apt-get -y install libnet-ssleay-perl libauthen-pam-perl apt-show-versions libio-pty-perl libapt-pkg-perl
	if [ ! -d /usr/share/webmin/ ]; then
		wget http://www.webmin.com/download/deb/webmin-current.deb
		dpkg -i webmin-current.deb
		rm -rf webmin-current.deb
	fi
}

function secure_ssh(){
	if [ $(grep -m 1 -c ${UNPRIV_USER} /etc/passwd) -eq 0 ]; then
		useradd -m ${UNPRIV_USER}
	fi

	if [ $(grep -m 1 -c "${UNPRIV_USER} pass" /root/auth.txt) -eq 0 ]; then
		USER_PASS=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32);
		echo "${UNPRIV_USER}:${USER_PASS}" | chpasswd
		echo "${UNPRIV_USER} pass: ${USER_PASS}" >> /root/auth.txt
	fi

	sed -i.save 's/#\?Port [0-9]\+/Port 3838/' /etc/ssh/sshd_config
	sed -i.save 's/#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
	service ssh restart
}

install_postgresql;
install_webmin;
secure_ssh;

apt-get install pgbouncer
apt-get install libpq-dev

#7. change root password
if [ $(grep -m 1 -c 'root pass' /root/auth.txt) -eq 0 ]; then
	ROOT_PASS=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32);
	echo "root:${ROOT_PASS}" | chpasswd
	echo "root pass: ${ROOT_PASS}" >> /root/auth.txt
fi

#8. Set firewall rules you will have to set in Webmin
cat >/etc/iptables.save <<EOF
# Generated
*nat
:PREROUTING ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
COMMIT
# Completed
# Generated
*mangle
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
COMMIT
# Completed
# Generated
*filter
:FORWARD ACCEPT [0:0]
:INPUT DROP [0:0]
:OUTPUT ACCEPT [0:0]
# Accept traffic from internal interfaces
-A INPUT ! -i eth0 -j ACCEPT
# Accept traffic with the ACK flag set
-A INPUT -p tcp -m tcp --tcp-flags ACK ACK -j ACCEPT
# Allow incoming data that is part of a connection we established
-A INPUT -m state --state ESTABLISHED -j ACCEPT
# Allow data that is related to existing connections
-A INPUT -m state --state RELATED -j ACCEPT
# Accept responses to DNS queries
-A INPUT -p udp -m udp --dport 1024:65535 --sport 53 -j ACCEPT
# Accept responses to our pings
-A INPUT -p icmp -m icmp --icmp-type echo-reply -j ACCEPT
# Accept notifications of unreachable hosts
-A INPUT -p icmp -m icmp --icmp-type destination-unreachable -j ACCEPT
# Accept notifications to reduce sending speed
-A INPUT -p icmp -m icmp --icmp-type source-quench -j ACCEPT
# Accept notifications of lost packets
-A INPUT -p icmp -m icmp --icmp-type time-exceeded -j ACCEPT
# Accept notifications of protocol problems
-A INPUT -p icmp -m icmp --icmp-type parameter-problem -j ACCEPT
# Allow connections to our SSH server
-A INPUT -p tcp -m tcp --dport 3838 -j ACCEPT
# Allow connections to our IDENT server
-A INPUT -p tcp -m tcp --dport auth -j ACCEPT
# Respond to pings
-A INPUT -p icmp -m icmp --icmp-type echo-request -j ACCEPT
# Allow DNS zone transfers
-A INPUT -p tcp -m tcp --dport 53 -j ACCEPT
# Allow DNS queries
-A INPUT -p udp -m udp --dport 53 -j ACCEPT
# Allow connections to webserver
-A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
# Allow SSL connections to webserver
-A INPUT -p tcp -m tcp --dport 443 -j ACCEPT
# Allow connections to mail server
-A INPUT -p tcp -m tcp -m multiport -j ACCEPT --dports 25,587
# Allow connections to FTP server
-A INPUT -p tcp -m tcp --dport 20:21 -j ACCEPT
# Allow connections to POP3 server
-A INPUT -p tcp -m tcp -m multiport -j ACCEPT --dports 110,995
# Allow connections to IMAP server
-A INPUT -p tcp -m tcp -m multiport -j ACCEPT --dports 143,220,993
# Allow connections to Webmin
-A INPUT -p tcp -m tcp --dport 10000:10010 -j ACCEPT
# Allow connections to Usermin
-A INPUT -p tcp -m tcp --dport 20000 -j ACCEPT
# Postgres
-A INPUT -p tcp -m tcp --dport 5432 -j ACCEPT
# pgbouncer
-A INPUT -p tcp -m tcp --dport 6432 -j ACCEPT
COMMIT
EOF

cat >/etc/network/if-pre-up.d/iptablesload <<EOF
#!/bin/sh
iptables-restore < /etc/iptables.rules
exit 0
EOF

#9. Set webmin config
cat >/etc/webmin/postgresql/config <<EOF
simple_sched=0
sameunix=1
date_subs=0
max_text=1000
perpage=25
stop_cmd=service postgresql stop
psql=/usr/bin/psql
pid_file=/var/run/postgresql/${PG_VER}-main.pid
hba_conf=/etc/postgresql/${PG_VER}/main/pg_hba.conf
setup_cmd=service postgresql start
user=postgres
nodbi=0
max_dbs=50
start_cmd=service postgresql start
repository=/var/lib/pgsql/${PG_VER}/backups
dump_cmd=/usr/bin/pg_dump
access=*: *
webmin_subs=0
style=0
rstr_cmd=/usr/bin/pg_restore
access_own=0
login=postgres
basedb=template1
add_mode=1
blob_mode=0
pass=${PG_PASS}
plib=
encoding=
port=
host=
EOF
service webmin restart

sed -i.save 's/#\?Port [0-9]\+/Port 3838/' /etc/ssh/sshd_config
service ssh restart

#webmin will complain about this but will convert the file for you
iptables-restore < /etc/iptables.save

echo "Passwords saved in /root/auth.txt"
cat /root/auth.txt

