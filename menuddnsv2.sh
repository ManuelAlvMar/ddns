#!/bin/bash

clear

# ========================================================
# 1. PREPARACIÓN INICIAL
# ========================================================
VERSION="8.0"
DIR="despliegue_ddns"
mkdir -p "$DIR"

CONFIG="$DIR/named.conf.local"
CONFIG_SLAVE="$DIR/named.conf.local.slave"
DHCP_CONF="$DIR/dhcpd.conf.generado"
DHCP_DEFAULT="$DIR/isc-dhcp-server.generado"
APPARMOR_FILE="$DIR/apparmor.named.generado"
INSTALL_SCRIPT="$DIR/instalar.sh"
CLIENTES_DIR="$DIR/clientes"

echo "" > "$CONFIG"
echo "" > "$DHCP_CONF"
echo "" > "$APPARMOR_FILE"
CARPETA_ESCLAVOS=""
CARPETA_ZONAS=""

# ========================================================
# FUNCIONES AUXILIARES
# ========================================================

separador() { echo "=========================================================="; }
subtitulo() { echo; echo "--- $1 ---"; }

preguntar_carpeta_zonas() {
    echo
    read -p "Carpeta de zonas en /etc/bind/ [Enter = zonas]: " CARPETA_ZONAS
    CARPETA_ZONAS=${CARPETA_ZONAS:-zonas}
    echo "  --> Se usará: /etc/bind/$CARPETA_ZONAS/"
    mkdir -p "$DIR/$CARPETA_ZONAS"
}

# Pide datos de un host genérico: hostname, alias CNAME, IP
# Uso: pedir_host "MASTER DNS" HOST_MASTER ALIAS_MASTER IP_MASTER
pedir_host() {
    local ETIQUETA="$1"
    local _HOST=$2 _ALIAS=$3 _IP=$4
    echo
    echo "  [ $ETIQUETA ]"
    read -p "  Hostname (ej: srv01):          " tmp_host
    read -p "  Alias CNAME (ej: master, ns1): " tmp_alias
    read -p "  IP:                            " tmp_ip
    eval "$_HOST='$tmp_host'"
    eval "$_ALIAS='$tmp_alias'"
    eval "$_IP='$tmp_ip'"
}

# Escribe en zona directa: A + CNAME
zona_add_host() {
    local FICHERO="$1" HOST="$2" ALIAS="$3" IP="$4" DOM="$5"
    printf "%-20s IN  A      %s\n" "$HOST" "$IP"        >> "$FICHERO"
    if [[ -n "$ALIAS" ]]; then
        printf "%-20s IN  CNAME  %s\n" "$ALIAS" "$HOST.$DOM." >> "$FICHERO"
    fi
}

# ========================================================
# 2. MENÚ PRINCIPAL
# ========================================================
separador
echo "   MEGA ASISTENTE BIND9 + DHCP v$VERSION (DEBIAN/UBUNTU)"
separador
echo "Elige el escenario que deseas configurar:"
echo ""
echo "  [DNS DINÁMICO]"
echo "  1) Modo Híbrido    : Esclavo de Principal + DDNS Maestro local"
echo "  2) Modo Puro       : Solo DDNS Maestro local (sin Maestro externo)"
echo "  3) Modo Delegado   : Esclavo de TODAS las zonas + DHCP al Maestro"
echo "  4) Modo Esclavo    : Solo DNS Esclavo (APAGA el DHCP local)"
echo ""
echo "  [DNS ESTÁTICO]"
echo "  5) Modo Estático   : Generador DNS clásico Master/Slave sin DHCP"
echo ""
echo "  [CLIENTES]"
echo "  9) Configurador de Clientes: IP fija/DHCP, DNS, hostname"
echo ""
echo "  [MANTENIMIENTO]"
echo "  6) Limpieza Total  : Resetear servidor (borrar rastros)"
echo "  7) Instalar paquetes: Update + Instalar BIND9 y DHCP"
echo ""
echo "  8) Salir"
separador
read -p "Opción [1-9]: " OPCION

if [[ "$OPCION" == "8" ]]; then
    echo "Saliendo del asistente..."
    rm -rf "$DIR"
    exit 0
fi

if [[ ! "$OPCION" =~ ^[1-7]$|^9$ ]]; then
    echo "Opción no válida. Saliendo."
    rm -rf "$DIR"
    exit 1
fi

# ========================================================
# OPCIÓN 7: INSTALAR PAQUETES
# ========================================================
if [[ "$OPCION" == "7" ]]; then
    cat > "$INSTALL_SCRIPT" << 'EOF'
#!/bin/bash
if [ "$EUID" -ne 0 ]; then echo "Usa: sudo ./instalar.sh"; exit 1; fi

echo "=========================================================="
echo "   INSTALADOR DE PAQUETES: BIND9 + ISC-DHCP-SERVER"
echo "=========================================================="

echo; echo "1. Actualizando lista de paquetes (apt update)..."
apt update || { echo "ERROR: Falló el apt update."; exit 1; }

echo; read -p "2. ¿Deseas hacer 'apt upgrade' ahora? (s/n, Enter=no): " HACER_UPGRADE
if [[ "$HACER_UPGRADE" == "s" || "$HACER_UPGRADE" == "S" ]]; then
    apt upgrade -y && echo "   --> Sistema actualizado."
else
    echo "   --> Upgrade omitido."
fi

echo; echo "3. Instalando bind9 y utilidades..."
apt install -y bind9 bind9utils bind9-doc || { echo "ERROR instalando bind9."; exit 1; }
echo "   --> bind9 OK."

echo; echo "4. Instalando isc-dhcp-server..."
apt install -y isc-dhcp-server || { echo "ERROR instalando isc-dhcp-server."; exit 1; }
echo "   --> isc-dhcp-server OK."

echo; echo "5. Estado de servicios:"
echo "----------------------------------------------------"
systemctl status bind9 --no-pager | grep -E "Active|Loaded"
systemctl status isc-dhcp-server --no-pager | grep -E "Active|Loaded"
echo "----------------------------------------------------"
echo; echo "¡INSTALACIÓN COMPLETADA! Vuelve a ejecutar el asistente."
EOF
    chmod +x "$INSTALL_SCRIPT"
    clear
    separador; echo "   SCRIPT DE INSTALACIÓN GENERADO"; separador
    echo "Ejecuta: sudo ./$DIR/instalar.sh"
    exit 0
fi

# ========================================================
# OPCIÓN 6: LIMPIEZA TOTAL
# ========================================================
if [[ "$OPCION" == "6" ]]; then
    echo
    echo "ADVERTENCIA: Borrará TODA la config de BIND9 y DHCP."
    read -p "¿Seguro? (escribe SI para confirmar): " CONFIRMAR
    if [[ "$CONFIRMAR" != "SI" ]]; then
        echo "Operación cancelada."; rm -rf "$DIR"; exit 0
    fi
    cat > "$INSTALL_SCRIPT" << 'EOF'
#!/bin/bash
if [ "$EUID" -ne 0 ]; then echo "Usa: sudo ./instalar.sh"; exit 1; fi

echo "=========================================================="
echo "   LIMPIEZA TOTAL DEL SERVIDOR DNS/DHCP"
echo "=========================================================="

systemctl stop isc-dhcp-server 2>/dev/null
systemctl disable isc-dhcp-server 2>/dev/null
echo "" > /etc/dhcp/dhcpd.conf
echo "   1. DHCP detenido y vaciado."

echo "" > /etc/bind/named.conf.local
echo "   2. named.conf.local vaciado."

rm -f /etc/bind/rndc.key /etc/dhcp/rndc.key
sed -i '/rndc.key/d' /etc/bind/named.conf
echo "   3. Llaves RNDC eliminadas."

for C in zonas esclavos; do
    [ -d "/etc/bind/$C" ] && rm -rf "/etc/bind/$C" && echo "   4. /etc/bind/$C eliminada."
done
rm -f /var/cache/bind/db.*

echo "" > /etc/apparmor.d/local/usr.sbin.named
systemctl reload apparmor
echo "   5. AppArmor restaurado."

systemctl restart bind9
echo; echo "¡SERVIDOR LIMPIO Y RESETEADO!"
systemctl status bind9 --no-pager | grep -E "Active|Loaded"
EOF
    chmod +x "$INSTALL_SCRIPT"
    clear
    separador; echo "   SCRIPT DE LIMPIEZA GENERADO"; separador
    echo "Ejecuta: sudo ./$DIR/instalar.sh"
    exit 0
fi

# ========================================================
# OPCIÓN 9: CONFIGURADOR DE CLIENTES
# ========================================================
if [[ "$OPCION" == "9" ]]; then
    mkdir -p "$CLIENTES_DIR"
    clear
    separador
    echo "   CONFIGURADOR DE CLIENTES (IP FIJA / DHCP / DNS)"
    separador
    echo "Este asistente genera un script listo para ejecutar en"
    echo "cada máquina cliente. Soporta Debian y Ubuntu."
    echo

    read -p "¿Cuántos clientes vas a configurar? (ej: 3): " NUM_CLIENTES
    if [[ ! "$NUM_CLIENTES" =~ ^[0-9]+$ ]] || [[ $NUM_CLIENTES -lt 1 ]]; then
        echo "Número no válido. Saliendo."; rm -rf "$DIR"; exit 1
    fi

    for ((cl=1; cl<=NUM_CLIENTES; cl++)); do
        echo
        separador
        echo "  CLIENTE $cl DE $NUM_CLIENTES"
        separador

        read -p "  Nombre/hostname del cliente (ej: pc01):      " CLI_HOSTNAME
        read -p "  Dominio al que pertenece (ej: empresa.local): " CLI_DOMINIO
        FQDN="${CLI_HOSTNAME}.${CLI_DOMINIO}"

        echo
        echo "  Sistema operativo:"
        echo "    1) Detectar automáticamente al instalar"
        echo "    2) Debian"
        echo "    3) Ubuntu (Netplan)"
        read -p "  Elige [1-3, Enter=1]: " CLI_SO
        CLI_SO=${CLI_SO:-1}

        echo
        read -p "  Interfaz de red (ej: ens18, eth0, Enter=ens18): " CLI_IFACE
        CLI_IFACE=${CLI_IFACE:-ens18}

        echo
        echo "  Tipo de configuración de IP:"
        echo "    1) IP fija (estática)"
        echo "    2) DHCP (IP automática)"
        read -p "  Elige [1-2]: " CLI_TIPO_IP

        CLI_IP=""; CLI_GW=""; CLI_MASK=""; CLI_MASK_CIDR=""
        if [[ "$CLI_TIPO_IP" == "1" ]]; then
            read -p "  IP estática del cliente (ej: 192.168.1.50):   " CLI_IP
            read -p "  Puerta de enlace / Gateway (ej: 192.168.1.1): " CLI_GW
            read -p "  Máscara CIDR (ej: 24):                        " CLI_MASK_CIDR
            # Calcular notación decimal de la máscara
            case "$CLI_MASK_CIDR" in
                8)  CLI_MASK="255.0.0.0" ;;
                16) CLI_MASK="255.255.0.0" ;;
                24) CLI_MASK="255.255.255.0" ;;
                25) CLI_MASK="255.255.255.128" ;;
                26) CLI_MASK="255.255.255.192" ;;
                27) CLI_MASK="255.255.255.224" ;;
                28) CLI_MASK="255.255.255.240" ;;
                *)  CLI_MASK="255.255.255.0" ;;
            esac
        fi

        echo
        echo "  Servidores DNS (nameservers):"
        read -p "  DNS primario (ej: 192.168.1.10):               " CLI_DNS1
        read -p "  DNS secundario (Enter para omitir):            " CLI_DNS2
        read -p "  DNS de fallback externo (Enter=8.8.8.8):       " CLI_DNS_EXTRA
        CLI_DNS_EXTRA=${CLI_DNS_EXTRA:-8.8.8.8}

        # Construir lista DNS
        CLI_DNS_LIST="$CLI_DNS1"
        [[ -n "$CLI_DNS2" ]] && CLI_DNS_LIST="$CLI_DNS_LIST $CLI_DNS2"
        CLI_DNS_LIST="$CLI_DNS_LIST $CLI_DNS_EXTRA"
        CLI_DNS_SEARCH="$CLI_DOMINIO"

        # Hosts adicionales en /etc/hosts
        echo
        read -p "  ¿Añadir entradas estáticas a /etc/hosts? (s/n): " CLI_EXTRA_HOSTS
        declare -a CLI_HOSTS_IPS
        declare -a CLI_HOSTS_NAMES
        NUM_EXTRA_HOSTS=0
        if [[ "$CLI_EXTRA_HOSTS" == "s" || "$CLI_EXTRA_HOSTS" == "S" ]]; then
            read -p "  ¿Cuántas entradas? (ej: 2): " NUM_EXTRA_HOSTS
            for ((eh=1; eh<=NUM_EXTRA_HOSTS; eh++)); do
                echo "    Entrada $eh:"
                read -p "      IP:     " CLI_HOSTS_IPS[$eh]
                read -p "      FQDN (ej: server.empresa.local): " CLI_HOSTS_NAMES[$eh]
            done
        fi

        # ── GENERAR SCRIPT DEL CLIENTE ──────────────────────────────
        SCRIPT_CLIENTE="$CLIENTES_DIR/configurar_${CLI_HOSTNAME}.sh"

        cat > "$SCRIPT_CLIENTE" << EOFC
#!/bin/bash
# ============================================================
# Script de configuración de red para: $FQDN
# Generado por Mega Asistente BIND9+DHCP v$VERSION
# ============================================================

if [ "\$EUID" -ne 0 ]; then
  echo "Usa: sudo ./configurar_${CLI_HOSTNAME}.sh"
  exit 1
fi

CLI_HOSTNAME="$CLI_HOSTNAME"
CLI_DOMINIO="$CLI_DOMINIO"
CLI_FQDN="$FQDN"
CLI_IFACE="$CLI_IFACE"
CLI_IP="$CLI_IP"
CLI_GW="$CLI_GW"
CLI_MASK="$CLI_MASK"
CLI_MASK_CIDR="$CLI_MASK_CIDR"
CLI_DNS1="$CLI_DNS1"
CLI_DNS2="$CLI_DNS2"
CLI_DNS_EXTRA="$CLI_DNS_EXTRA"
CLI_DNS_LIST="$CLI_DNS_LIST"
CLI_SO_ELEGIDO="$CLI_SO"

echo "============================================================"
echo "  CONFIGURANDO CLIENTE: \$CLI_FQDN"
echo "============================================================"

# ── 1. DETECTAR SO ─────────────────────────────────────────
if [[ "\$CLI_SO_ELEGIDO" == "1" ]]; then
    if grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        SO_DETECTADO="ubuntu"
    elif grep -qi "debian" /etc/os-release 2>/dev/null; then
        SO_DETECTADO="debian"
    else
        echo "No se pudo detectar el SO. Especifica manualmente (debian/ubuntu):"
        read -p "SO: " SO_DETECTADO
    fi
elif [[ "\$CLI_SO_ELEGIDO" == "2" ]]; then
    SO_DETECTADO="debian"
elif [[ "\$CLI_SO_ELEGIDO" == "3" ]]; then
    SO_DETECTADO="ubuntu"
fi

echo "  SO detectado/elegido: \$SO_DETECTADO"
echo

# ── 2. HOSTNAME ─────────────────────────────────────────────
echo "1. Configurando hostname..."
hostnamectl set-hostname "\$CLI_HOSTNAME"
echo "   --> hostname: \$CLI_HOSTNAME"

# ── 3. /etc/hosts ───────────────────────────────────────────
echo
echo "2. Configurando /etc/hosts..."
# Línea propia del equipo
if grep -q "127.0.1.1" /etc/hosts; then
    sed -i "s/^127.0.1.1.*/127.0.1.1\t\$CLI_FQDN\t\$CLI_HOSTNAME/" /etc/hosts
else
    echo -e "127.0.1.1\t\$CLI_FQDN\t\$CLI_HOSTNAME" >> /etc/hosts
fi
EOFC

        # Entradas extras en /etc/hosts
        if [[ $NUM_EXTRA_HOSTS -gt 0 ]]; then
            for ((eh=1; eh<=NUM_EXTRA_HOSTS; eh++)); do
                echo "echo -e \"${CLI_HOSTS_IPS[$eh]}\t${CLI_HOSTS_NAMES[$eh]}\" >> /etc/hosts" >> "$SCRIPT_CLIENTE"
            done
        fi

        cat >> "$SCRIPT_CLIENTE" << EOFC
echo "   --> /etc/hosts actualizado."

# ── 4. CONFIGURACIÓN DE RED ─────────────────────────────────
echo
echo "3. Configurando red en interfaz: \$CLI_IFACE (\$SO_DETECTADO)..."

if [[ "\$SO_DETECTADO" == "ubuntu" ]]; then
    # ── UBUNTU: NETPLAN ─────────────────────────────────────
    NETPLAN_FILE=\$(ls /etc/netplan/*.yaml 2>/dev/null | head -1)
    if [[ -z "\$NETPLAN_FILE" ]]; then
        NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
    fi
    echo "   Fichero Netplan: \$NETPLAN_FILE"
    cp "\$NETPLAN_FILE" "\${NETPLAN_FILE}.bak.\$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
EOFC

        if [[ "$CLI_TIPO_IP" == "1" ]]; then
            cat >> "$SCRIPT_CLIENTE" << EOFC
    cat > "\$NETPLAN_FILE" << NETPLAN
network:
  version: 2
  renderer: networkd
  ethernets:
    $CLI_IFACE:
      dhcp4: no
      addresses:
        - $CLI_IP/$CLI_MASK_CIDR
      routes:
        - to: default
          via: $CLI_GW
      nameservers:
        addresses: [$(echo "$CLI_DNS_LIST" | tr ' ' ',')]
        search: [$CLI_DOMINIO]
NETPLAN
EOFC
        else
            cat >> "$SCRIPT_CLIENTE" << EOFC
    cat > "\$NETPLAN_FILE" << NETPLAN
network:
  version: 2
  renderer: networkd
  ethernets:
    $CLI_IFACE:
      dhcp4: yes
      nameservers:
        addresses: [$(echo "$CLI_DNS_LIST" | tr ' ' ',')]
        search: [$CLI_DOMINIO]
NETPLAN
EOFC
        fi

        cat >> "$SCRIPT_CLIENTE" << EOFC
    chmod 600 "\$NETPLAN_FILE"
    netplan apply
    echo "   --> Netplan aplicado."

elif [[ "\$SO_DETECTADO" == "debian" ]]; then
    # ── DEBIAN: /etc/network/interfaces ─────────────────────
    IFACES_FILE="/etc/network/interfaces"
    cp "\$IFACES_FILE" "\${IFACES_FILE}.bak.\$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

    # Eliminar bloque previo de esta interfaz si existe
    sed -i "/^auto $CLI_IFACE/,/^$/d" "\$IFACES_FILE" 2>/dev/null || true
EOFC

        if [[ "$CLI_TIPO_IP" == "1" ]]; then
            cat >> "$SCRIPT_CLIENTE" << EOFC
    cat >> "\$IFACES_FILE" << IFACES

auto $CLI_IFACE
iface $CLI_IFACE inet static
    address $CLI_IP
    netmask $CLI_MASK
    gateway $CLI_GW
    dns-nameservers $CLI_DNS_LIST
    dns-search $CLI_DOMINIO
IFACES
EOFC
        else
            cat >> "$SCRIPT_CLIENTE" << EOFC
    cat >> "\$IFACES_FILE" << IFACES

auto $CLI_IFACE
iface $CLI_IFACE inet dhcp
IFACES
EOFC
        fi

        cat >> "$SCRIPT_CLIENTE" << EOFC
    # ── DEBIAN: resolv.conf ──────────────────────────────────
    echo
    echo "4. Configurando /etc/resolv.conf (Debian)..."
    # Deshabilitar resolvconf si está activo para no sobreescribir
    if systemctl is-active --quiet resolvconf 2>/dev/null; then
        echo "   [info] resolvconf activo: escribiendo en /etc/resolvconf/resolv.conf.d/head"
        RESOLV_TARGET="/etc/resolvconf/resolv.conf.d/head"
    else
        RESOLV_TARGET="/etc/resolv.conf"
        # Quitar inmutabilidad si la tiene (systemd-resolved la pone)
        chattr -i "\$RESOLV_TARGET" 2>/dev/null || true
        # Desconectar de systemd-resolved si es un symlink
        if [ -L "\$RESOLV_TARGET" ]; then
            rm -f "\$RESOLV_TARGET"
        fi
    fi

    {
        echo "domain $CLI_DOMINIO"
        echo "search $CLI_DOMINIO"
EOFC
        # DNS entries en resolv.conf
        for dns in $CLI_DNS_LIST; do
            echo "        echo \"nameserver $dns\"" >> "$SCRIPT_CLIENTE"
        done

        cat >> "$SCRIPT_CLIENTE" << EOFC
    } > "\$RESOLV_TARGET"

    if command -v resolvconf &>/dev/null; then
        resolvconf -u 2>/dev/null || true
    fi
    echo "   --> resolv.conf configurado."

    # Aplicar interfaz
    echo
    echo "5. Reiniciando interfaz de red..."
    ifdown "$CLI_IFACE" 2>/dev/null || true
    ifup "$CLI_IFACE" 2>/dev/null || true
fi

# ── 5. VERIFICACIÓN ─────────────────────────────────────────
echo
echo "============================================================"
echo "  VERIFICACIÓN FINAL"
echo "============================================================"
echo "  Hostname:"; hostname -f 2>/dev/null || hostname
echo "  IP de la interfaz:"
ip addr show "$CLI_IFACE" 2>/dev/null | grep "inet " || echo "  (sin IP aún)"
echo "  Prueba DNS contra $CLI_DNS1:"
if command -v nslookup &>/dev/null; then
    nslookup "$CLI_DOMINIO" "$CLI_DNS1" 2>/dev/null | grep -E "Server|Address|Name" || echo "  (no resuelve aún — espera al reinicio)"
elif command -v dig &>/dev/null; then
    dig +short "$CLI_DOMINIO" @"$CLI_DNS1" 2>/dev/null || echo "  (no resuelve aún)"
else
    echo "  Instala dnsutils para verificar: apt install dnsutils"
fi
echo "============================================================"
echo "  ¡CLIENTE $CLI_HOSTNAME CONFIGURADO!"
echo "  Reinicia el equipo si los cambios no surten efecto:"
echo "  reboot"
echo "============================================================"
EOFC

        chmod +x "$SCRIPT_CLIENTE"
        echo
        echo "  --> Script generado: $SCRIPT_CLIENTE"
    done

    # Resumen final de clientes
    clear
    separador
    echo "   SCRIPTS DE CLIENTE GENERADOS (v$VERSION)"
    separador
    echo "Se han generado $NUM_CLIENTES scripts en: $CLIENTES_DIR/"
    echo
    for f in "$CLIENTES_DIR"/configurar_*.sh; do
        echo "  $(basename $f)"
    done
    echo
    echo "Cómo usar en cada cliente:"
    echo "  1) Copia el script a la máquina cliente"
    echo "  2) chmod +x configurar_<nombre>.sh"
    echo "  3) sudo ./configurar_<nombre>.sh"
    separador
    exit 0
fi

# ========================================================
# OPCIÓN 5: GENERADOR DNS ESTÁTICO (Master/Slave clásico)
# ========================================================
if [[ "$OPCION" == "5" ]]; then
    echo "" > "$CONFIG_SLAVE"
    echo
    separador
    echo "     GENERADOR COMPLETO DNS BIND9 — Modo Estático"
    separador

    preguntar_carpeta_zonas

    d=1
    while true; do
        echo
        echo "=========== DOMINIO PRINCIPAL $d ==========="
        read -p "Dominio principal (ej: dominio.org): " DOM
        read -p "Red dominio principal (ej: 2.4.6):  " RED
        read -p "Máscara CIDR (ej: 24):               " MASK

        echo
        echo "ATENCION: El correo debe llevar punto en vez de @ y terminar en punto."
        echo "  Ejemplo: admin.miempresa.com."
        read -p "Correo administrador: " ADMIN

        pedir_host "MASTER DNS" HOST_MASTER ALIAS_MASTER IP_MASTER
        pedir_host "SLAVE DNS (red principal)" HOST_SLAVE ALIAS_SLAVE IP_SLAVE_MAIN

        INVERSA=$(echo $RED | awk -F. '{print $3"."$2"."$1}')

        # named.conf.local MASTER
        cat >> "$CONFIG" << EOF

//////////////////////////////////////////////////
// DOMINIO $DOM
//////////////////////////////////////////////////

zone "$DOM" {
    type master;
    file "/etc/bind/$CARPETA_ZONAS/db.$DOM";
    allow-query { any; };
    allow-transfer { $IP_SLAVE_MAIN; };
    also-notify { $IP_SLAVE_MAIN; };
    notify yes;
};

zone "$INVERSA.in-addr.arpa" {
    type master;
    file "/etc/bind/$CARPETA_ZONAS/db.$RED";
    allow-query { any; };
    allow-transfer { $IP_SLAVE_MAIN; };
    also-notify { $IP_SLAVE_MAIN; };
    notify yes;
};
EOF

        # named.conf.local SLAVE
        cat >> "$CONFIG_SLAVE" << EOF

//////////////////////////////////////////////////
// DOMINIO $DOM
//////////////////////////////////////////////////

zone "$DOM" {
    type slave;
    file "/etc/bind/$CARPETA_ZONAS/db.$DOM";
    masters { $IP_MASTER; };
    allow-query { any; };
};

zone "$INVERSA.in-addr.arpa" {
    type slave;
    file "/etc/bind/$CARPETA_ZONAS/db.$RED";
    masters { $IP_MASTER; };
    allow-query { any; };
};
EOF

        # ZONA DIRECTA DOMINIO PRINCIPAL
        DIRECTO="$DIR/$CARPETA_ZONAS/db.$DOM"
        cat > "$DIRECTO" << EOF
\$TTL 604800
@   IN  SOA     $DOM. $ADMIN (
                2          ; Serial
                604800     ; Refresh
                86400      ; Retry
                2419200    ; Expire
                604800 )   ; Negative Cache TTL

; --- Name Servers ---
@               IN  NS      $HOST_MASTER.$DOM.
@               IN  NS      $HOST_SLAVE.$DOM.

; --- Resolución del dominio base ---
@               IN  A       $IP_MASTER

; --- Servidores DNS ---
EOF
        zona_add_host "$DIRECTO" "$HOST_MASTER" "$ALIAS_MASTER" "$IP_MASTER" "$DOM"
        zona_add_host "$DIRECTO" "$HOST_SLAVE"  "$ALIAS_SLAVE"  "$IP_SLAVE_MAIN" "$DOM"

        # HOSTS EXTRA DOMINIO PRINCIPAL
        echo
        read -p "Número de hosts/servidores extra del dominio principal (0 si no hay): " NUM_HOSTS
        declare -a HOSTNAMES HOSTIPS

        if [[ $NUM_HOSTS -gt 0 ]]; then
            echo
            for ((h=1; h<=NUM_HOSTS; h++)); do
                pedir_host "HOST EXTRA $h" HOSTNAMES[$h] tmp_alias_h HOSTIPS[$h]
                zona_add_host "$DIRECTO" "${HOSTNAMES[$h]}" "$tmp_alias_h" "${HOSTIPS[$h]}" "$DOM"
            done
        fi

        # ZONA INVERSA DOMINIO PRINCIPAL
        INVERSO="$DIR/$CARPETA_ZONAS/db.$RED"
        cat > "$INVERSO" << EOF
\$TTL 604800
@   IN  SOA     $INVERSA.in-addr.arpa. $ADMIN (
                2
                604800
                86400
                2419200
                604800 )

@               IN  NS  $HOST_MASTER.$DOM.
@               IN  NS  $HOST_SLAVE.$DOM.

EOF
        # PTR master y slave siempre
        OCT_MASTER=$(echo $IP_MASTER    | awk -F. '{print $4}')
        OCT_SLAVE=$(echo  $IP_SLAVE_MAIN | awk -F. '{print $4}')
        printf "%-6s IN  PTR  %s\n" "$OCT_MASTER" "$HOST_MASTER.$DOM." >> "$INVERSO"
        printf "%-6s IN  PTR  %s\n" "$OCT_SLAVE"  "$HOST_SLAVE.$DOM."  >> "$INVERSO"

        if [[ $NUM_HOSTS -gt 0 ]]; then
            for ((h=1; h<=NUM_HOSTS; h++)); do
                OCTETO=$(echo ${HOSTIPS[$h]} | awk -F. '{print $4}')
                echo
                echo "  PTR detectado: $OCTETO --> ${HOSTNAMES[$h]}.$DOM."
                read -p "  ¿Añadir registro PTR? (s/n): " RESP
                [[ $RESP == "s" || $RESP == "S" ]] && printf "%-6s IN  PTR  %s\n" "$OCTETO" "${HOSTNAMES[$h]}.$DOM." >> "$INVERSO"
            done
        fi

        # SUBDOMINIOS
        echo
        read -p "Número de subdominios para $DOM (0 si no hay): " NUM_SUB

        if [[ $NUM_SUB -gt 0 ]]; then
            for ((s=1; s<=NUM_SUB; s++)); do
                echo
                echo "=========== SUBDOMINIO $s ==========="
                read -p "Nombre subdominio (ej: subdominio1): " SUB
                read -p "Red subdominio (ej: 1.3.5):          " REDSUB
                read -p "Máscara subdominio (ej: 24):         " MASKSUB

                pedir_host "SLAVE DNS en subdominio $SUB" HOST_SLAVE_SUB ALIAS_SLAVE_SUB IP_SLAVE_SUB

                INV_SUB=$(echo $REDSUB | awk -F. '{print $3"."$2"."$1}')

                cat >> "$CONFIG" << EOF

zone "$SUB.$DOM" {
    type master;
    file "/etc/bind/$CARPETA_ZONAS/db.$SUB.$DOM";
    allow-query { any; };
    allow-transfer { $IP_SLAVE_MAIN; };
    also-notify { $IP_SLAVE_MAIN; };
    notify yes;
};

zone "$INV_SUB.in-addr.arpa" {
    type master;
    file "/etc/bind/$CARPETA_ZONAS/db.$REDSUB";
    allow-query { any; };
    allow-transfer { $IP_SLAVE_MAIN; };
    also-notify { $IP_SLAVE_MAIN; };
    notify yes;
};
EOF
                cat >> "$CONFIG_SLAVE" << EOF

zone "$SUB.$DOM" {
    type slave;
    file "/etc/bind/$CARPETA_ZONAS/db.$SUB.$DOM";
    masters { $IP_MASTER; };
    allow-query { any; };
};

zone "$INV_SUB.in-addr.arpa" {
    type slave;
    file "/etc/bind/$CARPETA_ZONAS/db.$REDSUB";
    masters { $IP_MASTER; };
    allow-query { any; };
};
EOF

                DIRECT_SUB="$DIR/$CARPETA_ZONAS/db.$SUB.$DOM"
                cat > "$DIRECT_SUB" << EOF
\$TTL 604800
@   IN  SOA     $SUB.$DOM. $ADMIN (
                2
                604800
                86400
                2419200
                604800 )

@               IN  NS  $HOST_MASTER.$DOM.
@               IN  NS  $HOST_SLAVE.$DOM.

@               IN  A   $IP_MASTER

EOF
                zona_add_host "$DIRECT_SUB" "$HOST_SLAVE_SUB" "$ALIAS_SLAVE_SUB" "$IP_SLAVE_SUB" "$SUB.$DOM"

                # Hosts extra en el subdominio
                echo
                read -p "Número de hosts extra en el subdominio $SUB (0 si no hay): " NUM_HOST_SUB
                declare -a SUBHOSTNAMES SUBHOSTIPS
                if [[ $NUM_HOST_SUB -gt 0 ]]; then
                    for ((hs=1; hs<=NUM_HOST_SUB; hs++)); do
                        pedir_host "HOST SUBDOMINIO $hs" SUBHOSTNAMES[$hs] tmp_alias_sub SUBHOSTIPS[$hs]
                        zona_add_host "$DIRECT_SUB" "${SUBHOSTNAMES[$hs]}" "$tmp_alias_sub" "${SUBHOSTIPS[$hs]}" "$SUB.$DOM"
                    done
                fi

                INV_SUB_FILE="$DIR/$CARPETA_ZONAS/db.$REDSUB"
                cat > "$INV_SUB_FILE" << EOF
\$TTL 604800
@   IN  SOA     $INV_SUB.in-addr.arpa. $ADMIN (
                2
                604800
                86400
                2419200
                604800 )

@               IN  NS  $HOST_MASTER.$DOM.
@               IN  NS  $HOST_SLAVE.$DOM.

EOF
                OCT_SLAVE_SUB=$(echo $IP_SLAVE_SUB | awk -F. '{print $4}')
                printf "%-6s IN  PTR  %s\n" "$OCT_SLAVE_SUB" "$HOST_SLAVE_SUB.$SUB.$DOM." >> "$INV_SUB_FILE"

                if [[ $NUM_HOST_SUB -gt 0 ]]; then
                    for ((ps=1; ps<=NUM_HOST_SUB; ps++)); do
                        OCTETO=$(echo ${SUBHOSTIPS[$ps]} | awk -F. '{print $4}')
                        echo
                        echo "  PTR detectado: $OCTETO --> ${SUBHOSTNAMES[$ps]}.$SUB.$DOM."
                        read -p "  ¿Añadir registro PTR? (s/n): " RESP
                        [[ $RESP == "s" || $RESP == "S" ]] && printf "%-6s IN  PTR  %s\n" "$OCTETO" "${SUBHOSTNAMES[$ps]}.$SUB.$DOM." >> "$INV_SUB_FILE"
                    done
                fi
            done
        fi

        echo
        separador
        read -p "¿Deseas añadir otro dominio principal? (s/n): " RESP_DOM
        [[ "$RESP_DOM" != "s" && "$RESP_DOM" != "S" ]] && break
        ((d++))
    done

    # INSTALADOR ESTÁTICO
    CARPETA_ZONAS_SAVED="$CARPETA_ZONAS"
    cat > "$INSTALL_SCRIPT" << EOFI
#!/bin/bash
cd "\$(dirname "\$0")" || exit 1
if [ "\$EUID" -ne 0 ]; then echo "Usa: sudo ./instalar.sh"; exit 1; fi

CARPETA_ZONAS="$CARPETA_ZONAS_SAVED"

echo "0. Limpiando CRLF de Windows..."
sed -i 's/\r//g' named.conf.local named.conf.local.slave 2>/dev/null || true

echo "================================================="
echo "   INSTALADOR DNS ESTÁTICO (BIND9) v$VERSION"
echo "================================================="
echo "¿Rol de esta máquina?"
echo "  1) Servidor Maestro"
echo "  2) Servidor Esclavo"
read -p "Elige [1-2]: " ROL_MAQUINA

systemctl stop isc-dhcp-server 2>/dev/null
systemctl disable isc-dhcp-server 2>/dev/null

mkdir -p /etc/bind/\$CARPETA_ZONAS

if [ "\$ROL_MAQUINA" == "1" ]; then
    cp named.conf.local /etc/bind/
    cp \$CARPETA_ZONAS/* /etc/bind/\$CARPETA_ZONAS/ 2>/dev/null || true
elif [ "\$ROL_MAQUINA" == "2" ]; then
    cp named.conf.local.slave /etc/bind/named.conf.local
else
    echo "Opción no válida."; exit 1
fi

chown -R bind:bind /etc/bind/\$CARPETA_ZONAS
chmod -R 775 /etc/bind/\$CARPETA_ZONAS
systemctl restart bind9

echo "----------------------------------------------------"
systemctl status bind9 --no-pager | grep -E "Active|Loaded"
echo "----------------------------------------------------"
EOFI
    chmod +x "$INSTALL_SCRIPT"

    clear
    separador
    echo " CONFIGURACIÓN ESTÁTICA GENERADA (v$VERSION)"
    separador
    echo "Carpeta: $DIR/  |  Zonas: /etc/bind/$CARPETA_ZONAS/"
    echo
    echo "Lleva la carpeta '$DIR' a ambas máquinas y ejecuta:"
    echo "  sudo ./instalar.sh"
    separador
    exit 0
fi

# ========================================================
# FLUJO NORMAL (OPCIONES 1 a 4) — MODOS DDNS
# ========================================================
preguntar_carpeta_zonas

if [[ "$OPCION" != "4" ]]; then
    cat >> "$DHCP_CONF" << EOF
ddns-updates on;
ddns-update-style interim;
update-static-leases on;
ignore client-updates;
authoritative;
include "/etc/dhcp/rndc.key";
EOF

    echo "/etc/bind/$CARPETA_ZONAS/** rw," > "$APPARMOR_FILE"

    subtitulo "CONFIGURACIÓN DE RED (DHCP)"
    read -p "Interfaz(es) para DHCP (ej: ens19 o ens18 ens19): " INTERFAZ_DHCP
    cat > "$DHCP_DEFAULT" << EOF
INTERFACESv4="$INTERFAZ_DHCP"
INTERFACESv6=""
EOF
fi

# ──── ZONAS ESCLAVAS (OPCIONES 1, 3, 4) ─────────────────────
if [[ "$OPCION" == "1" || "$OPCION" == "3" || "$OPCION" == "4" ]]; then
    subtitulo "CONFIGURACIÓN DE ZONAS ESCLAVAS"
    read -p "¿Cuántas zonas vas a transferir del Maestro? (ej: 1): " NUM_SLAVES

    if [[ $NUM_SLAVES -gt 0 ]]; then
        read -p "IP del servidor Maestro (Windows o Linux) (ej: 192.168.1.10): " IP_MAESTRO
        read -p "Carpeta para estas zonas en /etc/bind/ [Enter = esclavos]: " CARPETA_ESCLAVOS
        CARPETA_ESCLAVOS=${CARPETA_ESCLAVOS:-esclavos}
        echo "  --> Se usará: /etc/bind/$CARPETA_ESCLAVOS/"

        echo "/etc/bind/$CARPETA_ESCLAVOS/** rw," >> "$APPARMOR_FILE"

        for ((s=1; s<=NUM_SLAVES; s++)); do
            echo; echo "=== ZONA ESCLAVA $s ==="
            read -p "Nombre del dominio (ej: principal.com): " DOM_SLAVE
            read -p "Red zona inversa (SOLO 3 OCTETOS, Enter si no tiene): " RED_INV_MASTER

            cat >> "$CONFIG" << EOF
// ==================================================
// ZONA ESCLAVA: $DOM_SLAVE
// ==================================================
zone "$DOM_SLAVE" {
    type slave;
    file "/etc/bind/$CARPETA_ESCLAVOS/db.$DOM_SLAVE";
    masters { $IP_MAESTRO; };
    allow-query { any; };
};
EOF
            if [[ -n "$RED_INV_MASTER" ]]; then
                INV_MASTER_ARPA=$(echo $RED_INV_MASTER | awk -F. '{print $3"."$2"."$1}')
                cat >> "$CONFIG" << EOF

zone "$INV_MASTER_ARPA.in-addr.arpa" {
    type slave;
    file "/etc/bind/$CARPETA_ESCLAVOS/db.$RED_INV_MASTER";
    masters { $IP_MAESTRO; };
    allow-query { any; };
};
EOF
            fi
        done
    fi
fi

# ──── ZONAS DDNS (OPCIONES 1, 2, 3) ─────────────────────────
if [[ "$OPCION" == "1" || "$OPCION" == "2" || "$OPCION" == "3" ]]; then
    subtitulo "ZONAS DDNS Y DHCP"
    read -p "¿Para cuántas subredes vas a configurar DHCP+DDNS? (ej: 1): " NUM_DDNS

    if [[ $NUM_DDNS -gt 0 ]]; then
        for ((d=1; d<=NUM_DDNS; d++)); do
            echo; echo "=== CONFIGURANDO RED DDNS $d ==="
            read -p "1. Nombre del dominio dinámico (ej: subred1.local): " DOM_DDNS
            read -p "2. Red (SOLO 3 OCTETOS) (ej: 1.3.5):                " RED_DDNS
            read -p "3. IP ESTÁTICA de este servidor Linux (ej: 1.3.5.4): " IP_LINUX_DDNS
            read -p "4. Hostname de este servidor DNS [Enter = ns1]:       " HOSTNAME_DNS
            HOSTNAME_DNS=${HOSTNAME_DNS:-ns1}
            read -p "5. Alias CNAME del servidor DNS [Enter = dns]:        " ALIAS_DNS
            ALIAS_DNS=${ALIAS_DNS:-dns}

            read -p "Tiempo de concesión por defecto en seg [Enter=600]:  " DEFAULT_LEASE
            DEFAULT_LEASE=${DEFAULT_LEASE:-600}
            read -p "Tiempo máximo de concesión en seg [Enter=7200]:       " MAX_LEASE
            MAX_LEASE=${MAX_LEASE:-7200}

            read -p "Primera IP que dará el DHCP (ej: 1.3.5.50):          " DHCP_START
            read -p "Última IP que dará el DHCP (ej: 1.3.5.100):          " DHCP_END

            read -p "¿Excluir un bloque de IPs en medio? (1=Sí, 0=No):   " TIENE_EXCLUSION
            RANGOS_DHCP=""
            if [[ "$TIENE_EXCLUSION" == "1" ]]; then
                read -p "   - PRIMERA IP de exclusión (ej: 1.3.5.70): " EXC_START
                read -p "   - ÚLTIMA IP de exclusión (ej: 1.3.5.80):  " EXC_END
                BASE_IP=$(echo $DHCP_START | cut -d. -f1-3)
                START_OCT=$(echo $DHCP_START | cut -d. -f4)
                END_OCT=$(echo $DHCP_END | cut -d. -f4)
                EXC_START_OCT=$(echo $EXC_START | cut -d. -f4)
                EXC_END_OCT=$(echo $EXC_END | cut -d. -f4)
                if [[ $START_OCT -lt $EXC_START_OCT ]]; then
                    R1_END=$((EXC_START_OCT - 1))
                    RANGOS_DHCP="    range $BASE_IP.$START_OCT $BASE_IP.$R1_END;"
                fi
                if [[ $END_OCT -gt $EXC_END_OCT ]]; then
                    R2_START=$((EXC_END_OCT + 1))
                    RANGOS_DHCP="${RANGOS_DHCP}
    range $BASE_IP.$R2_START $BASE_IP.$END_OCT;"
                fi
            else
                RANGOS_DHCP="    range $DHCP_START $DHCP_END;"
            fi

            INV_DDNS=$(echo $RED_DDNS | awk -F. '{print $3"."$2"."$1}')

            if [[ "$OPCION" == "3" ]]; then
                cat >> "$CONFIG" << EOF
zone "$DOM_DDNS" {
    type slave;
    file "/etc/bind/$CARPETA_ESCLAVOS/db.$DOM_DDNS";
    masters { $IP_MAESTRO; };
    allow-query { any; };
};

zone "$INV_DDNS.in-addr.arpa" {
    type slave;
    file "/etc/bind/$CARPETA_ESCLAVOS/db.$RED_DDNS";
    masters { $IP_MAESTRO; };
    allow-query { any; };
};
EOF
                cat >> "$DHCP_CONF" << EOF
zone $DOM_DDNS. { primary $IP_MAESTRO; key rndc-key; }
zone $INV_DDNS.in-addr.arpa. { primary $IP_MAESTRO; key rndc-key; }
EOF
            else
                cat >> "$CONFIG" << EOF
zone "$DOM_DDNS" {
    type master;
    file "/etc/bind/$CARPETA_ZONAS/db.$DOM_DDNS";
    allow-update { key "rndc-key"; };
    allow-query { any; };
};

zone "$INV_DDNS.in-addr.arpa" {
    type master;
    file "/etc/bind/$CARPETA_ZONAS/db.$RED_DDNS";
    allow-update { key "rndc-key"; };
    allow-query { any; };
};
EOF
                cat >> "$DHCP_CONF" << EOF
zone $DOM_DDNS. { primary 127.0.0.1; key rndc-key; }
zone $INV_DDNS.in-addr.arpa. { primary 127.0.0.1; key rndc-key; }
EOF
                # Zona directa DDNS
                ZONA_DDNS_FILE="$DIR/$CARPETA_ZONAS/db.$DOM_DDNS"
                cat > "$ZONA_DDNS_FILE" << EOF
\$ORIGIN $DOM_DDNS.
\$TTL 86400
@   IN  SOA     $HOSTNAME_DNS.$DOM_DDNS. admin.$DOM_DDNS. ( 1 3600 1800 604800 86400 )
@   IN  NS      $HOSTNAME_DNS.$DOM_DDNS.
EOF
                zona_add_host "$ZONA_DDNS_FILE" "$HOSTNAME_DNS" "$ALIAS_DNS" "$IP_LINUX_DDNS" "$DOM_DDNS"

                # Zona inversa DDNS
                ZONA_INV_DDNS="$DIR/$CARPETA_ZONAS/db.$RED_DDNS"
                cat > "$ZONA_INV_DDNS" << EOF
\$ORIGIN $INV_DDNS.in-addr.arpa.
\$TTL 86400
@   IN  SOA     $HOSTNAME_DNS.$DOM_DDNS. admin.$DOM_DDNS. ( 1 3600 1800 604800 86400 )
@   IN  NS      $HOSTNAME_DNS.$DOM_DDNS.
EOF
                OCT_LINUX=$(echo $IP_LINUX_DDNS | awk -F. '{print $4}')
                printf "%-6s IN  PTR  %s\n" "$OCT_LINUX" "$HOSTNAME_DNS.$DOM_DDNS." >> "$ZONA_INV_DDNS"
            fi

            cat >> "$DHCP_CONF" << EOF
subnet $RED_DDNS.0 netmask 255.255.255.0 {
$RANGOS_DHCP
    option domain-name          "$DOM_DDNS";
    option domain-name-servers  $IP_LINUX_DDNS;
    option routers              $IP_LINUX_DDNS;
    option broadcast-address    $RED_DDNS.255;
    default-lease-time          $DEFAULT_LEASE;
    max-lease-time              $MAX_LEASE;
}
EOF
        done
    fi
fi

# ========================================================
# SCRIPT INSTALADOR (OPCIONES 1 a 4)
# ========================================================
CARPETA_ZONAS_SAVED="$CARPETA_ZONAS"
CARPETA_ESCLAVOS_SAVED="$CARPETA_ESCLAVOS"
cat > "$INSTALL_SCRIPT" << EOFI
#!/bin/bash
cd "\$(dirname "\$0")" || exit 1
if [ "\$EUID" -ne 0 ]; then echo "Usa: sudo ./instalar.sh"; exit 1; fi

CARPETA_ZONAS="$CARPETA_ZONAS_SAVED"
CARPETA_ESCLAVOS="$CARPETA_ESCLAVOS_SAVED"

echo "0. Limpiando CRLF de Windows..."
sed -i 's/\r//g' named.conf.local dhcpd.conf.generado isc-dhcp-server.generado apparmor.named.generado 2>/dev/null || true

echo "1. Creando estructura de carpetas..."
mkdir -p /etc/bind/\$CARPETA_ZONAS
cp \$CARPETA_ZONAS/* /etc/bind/\$CARPETA_ZONAS/ 2>/dev/null || true

if [ -n "\$CARPETA_ESCLAVOS" ]; then
    mkdir -p /etc/bind/\$CARPETA_ESCLAVOS
    chown -R bind:bind /etc/bind/\$CARPETA_ESCLAVOS
    chmod -R 775 /etc/bind/\$CARPETA_ESCLAVOS
fi

echo "2. Copiando named.conf.local..."
cp named.conf.local /etc/bind/

if [ "$OPCION" == "4" ]; then
    echo "-> Modo Esclavo Puro: apagando DHCP..."
    echo "" > /etc/dhcp/dhcpd.conf
    systemctl stop isc-dhcp-server 2>/dev/null
    systemctl disable isc-dhcp-server 2>/dev/null
else
    cp dhcpd.conf.generado /etc/dhcp/dhcpd.conf
    cp isc-dhcp-server.generado /etc/default/isc-dhcp-server

    echo "3. Generando llave RNDC..."
    rm -f /etc/bind/rndc.key /etc/dhcp/rndc.key
    rndc-confgen -a -c /etc/bind/rndc.key -u bind
    cp /etc/bind/rndc.key /etc/dhcp/rndc.key
    chmod 640 /etc/bind/rndc.key
    chown root:root /etc/dhcp/rndc.key
    chmod 640 /etc/dhcp/rndc.key

    if ! grep -q 'include "/etc/bind/rndc.key";' /etc/bind/named.conf; then
        sed -i '1iinclude "/etc/bind/rndc.key";' /etc/bind/named.conf
    fi
fi

echo "4. Configurando AppArmor..."
cp apparmor.named.generado /etc/apparmor.d/local/usr.sbin.named
chown -R bind:bind /etc/bind/\$CARPETA_ZONAS
chmod -R 775 /etc/bind/\$CARPETA_ZONAS
systemctl reload apparmor

echo "5. Reiniciando servicios..."
systemctl restart bind9
if [ "$OPCION" != "4" ]; then
    systemctl restart isc-dhcp-server
fi

echo "----------------------------------------------------"
systemctl status bind9 --no-pager | grep -E "Active|Loaded"
if [ "$OPCION" != "4" ]; then
    systemctl status isc-dhcp-server --no-pager | grep -E "Active|Loaded"
fi
echo "----------------------------------------------------"
EOFI

chmod +x "$INSTALL_SCRIPT"

clear
separador
echo "    MEGA SCRIPT v$VERSION GENERADO CON ÉXITO"
separador
echo "Carpeta generada : $DIR/"
echo "Carpeta de zonas : /etc/bind/$CARPETA_ZONAS/"
echo
echo "Para instalar en el servidor:"
echo "  cd $DIR && sudo ./instalar.sh"
separador
