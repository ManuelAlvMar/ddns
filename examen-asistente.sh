#!/bin/bash
# ============================================================
# ASISTENTE DE EXAMEN - DHCP + DNS (BIND9)
# Para alumnos de 2º CFGS ASIR - Servicios de Red
# Genera TODOS los ficheros de configuración listos para usar
# ============================================================

clear
VERSION="1.0"
DIR="examen_salida"
rm -rf "$DIR"
mkdir -p "$DIR"

# ─── colores ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

sep()  { echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"; }
sep2() { echo -e "${YELLOW}──────────────────────────────────────────────────────${NC}"; }
ok()   { echo -e "  ${GREEN}✔${NC} $1"; }
info() { echo -e "  ${CYAN}→${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
titulo() { echo; sep; echo -e "  ${BOLD}$1${NC}"; sep; }

# ─── función: leer con valor por defecto ────────────────────
leer() {
    # leer "Pregunta" VAR [default]
    local PREGUNTA="$1" VAR="$2" DEFAULT="$3"
    if [[ -n "$DEFAULT" ]]; then
        read -p "  $PREGUNTA [Enter=$DEFAULT]: " tmp
        tmp=${tmp:-$DEFAULT}
    else
        read -p "  $PREGUNTA: " tmp
        while [[ -z "$tmp" ]]; do
            read -p "  (requerido) $PREGUNTA: " tmp
        done
    fi
    eval "$VAR='$tmp'"
}

# ─── función: mascara CIDR → decimal ────────────────────────
cidr_a_mascara() {
    local CIDR=$1
    case "$CIDR" in
        8)  echo "255.0.0.0" ;;
        16) echo "255.255.0.0" ;;
        24) echo "255.255.255.0" ;;
        25) echo "255.255.255.128" ;;
        26) echo "255.255.255.192" ;;
        27) echo "255.255.255.224" ;;
        28) echo "255.255.255.240" ;;
        *)  echo "255.255.255.0" ;;
    esac
}

# ─── función: zona inversa desde red ────────────────────────
red_a_inversa() {
    echo "$1" | awk -F. '{print $3"."$2"."$1}'
}

# ─── función: escribir registro A+CNAME en zona ─────────────
zona_a() {
    local FICH="$1" HOST="$2" ALIAS="$3" IP="$4" DOM="$5"
    printf "%-25s IN  A      %s\n" "$HOST" "$IP" >> "$FICH"
    [[ -n "$ALIAS" ]] && printf "%-25s IN  CNAME  %s.\n" "$ALIAS" "$HOST.$DOM" >> "$FICH"
}

# ─── función: escribir registro PTR ─────────────────────────
zona_ptr() {
    local FICH="$1" IP="$2" FQDN="$3"
    local OCT; OCT=$(echo "$IP" | awk -F. '{print $4}')
    printf "%-6s IN  PTR    %s.\n" "$OCT" "$FQDN" >> "$FICH"
}

# ─── función: cabecera SOA para zona directa ────────────────
zona_soa_directa() {
    local FICH="$1" DOM="$2" NS1="$3" ADMIN="$4"
    cat >> "$FICH" << EOF
\$TTL 86400
@   IN  SOA   $NS1.$DOM. $ADMIN.$DOM. (
              $(date +%Y%m%d)01 ; Serial
              3600              ; Refresh
              1800              ; Retry
              604800            ; Expire
              86400 )           ; Negative TTL

@             IN  NS    $NS1.$DOM.
EOF
}

# ─── función: cabecera SOA para zona inversa ────────────────
zona_soa_inversa() {
    local FICH="$1" INVERSA="$2" NS1="$3" DOM="$4" ADMIN="$5"
    cat >> "$FICH" << EOF
\$TTL 86400
@   IN  SOA   $NS1.$DOM. $ADMIN.$DOM. (
              $(date +%Y%m%d)01 ; Serial
              3600              ; Refresh
              1800              ; Retry
              604800            ; Expire
              86400 )           ; Negative TTL

@             IN  NS    $NS1.$DOM.
EOF
}

# ═══════════════════════════════════════════════════════════
#  BIENVENIDA
# ═══════════════════════════════════════════════════════════
titulo "ASISTENTE DE EXAMEN DHCP+DNS — v$VERSION"
echo -e "  Genera la configuración completa de TODAS las máquinas."
echo -e "  Lee el enunciado del examen e introduce los datos."
echo
echo -e "  Ficheros que se generarán en ${BOLD}$DIR/${NC}:"
echo -e "    • named.conf.local para cada servidor DNS"
echo -e "    • Ficheros de zona directa e inversa"
echo -e "    • dhcpd.conf y isc-dhcp-server para el servidor DHCP"
echo -e "    • /etc/hosts para máquinas sin DNS"
echo -e "    • Script de instalación para cada máquina"
echo
read -p "  Pulsa Enter para comenzar..."

# ═══════════════════════════════════════════════════════════
#  PASO 1 — ESTRUCTURA GENERAL DEL ESCENARIO
# ═══════════════════════════════════════════════════════════
titulo "PASO 1 — ESTRUCTURA DEL ESCENARIO"
echo -e "  Vamos a describir cuántas redes, dominios y servidores hay."
echo

leer "¿Cuántas REDES hay en total en el escenario?" NUM_REDES 3
leer "¿Cuántos dominios DNS hay (zonas directas+inversas a configurar)?" NUM_DOMINIOS 3

echo
echo -e "  ${BOLD}¿Qué servidores DNS hay?${NC} (pueden solaparse con clientes)"
leer "¿Hay servidor MASTER DNS? (s/n)" HAY_MASTER "s"
leer "¿Hay servidor SLAVE DNS? (s/n)" HAY_SLAVE "s"
leer "¿Hay servidor DDNS (Debian con BIND9+DHCP)? (s/n)" HAY_DDNS "s"
leer "¿Hay un segundo SLAVE? (s/n)" HAY_SLAVE2 "n"

echo
sep2
echo -e "  ${BOLD}Tipo de servidor MASTER:${NC}"
echo -e "    1) Windows DNS (no presta DHCP, solo DNS master)"
echo -e "    2) Linux Debian/Ubuntu"
leer "Tipo de MASTER [1=Windows, 2=Linux]" MASTER_TIPO "1"

# ═══════════════════════════════════════════════════════════
#  PASO 2 — DATOS DE CADA RED
# ═══════════════════════════════════════════════════════════
titulo "PASO 2 — DATOS DE CADA RED"

declare -a RED_DIR RED_DOMINIO RED_CIDR RED_GW RED_TIPO_DHCP RED_DHCP_RANGO RED_DHCP_TIEMPO

for ((r=1; r<=NUM_REDES; r++)); do
    echo
    sep2
    echo -e "  ${BOLD}RED $r${NC}"
    leer "Dirección de red (3 octetos, ej: 10.12.14)" RED_DIR[$r]
    leer "Dominio de esta red (ej: nombre.com)" RED_DOMINIO[$r]
    leer "Máscara CIDR (ej: 24)" RED_CIDR[$r] "24"
    leer "Gateway de esta red (solo último octeto, ej: 254)" RED_GW[$r] "254"

    echo -e "  ${BOLD}¿Qué tipo de DHCP tiene esta red?${NC}"
    echo -e "    0) Sin DHCP (IPs fijas o sin servicio)"
    echo -e "    1) DHCP en servidor Debian-DDNS"
    echo -e "    2) DHCP en servidor Linux independiente"
    leer "Tipo DHCP" RED_TIPO_DHCP[$r] "0"

    if [[ "${RED_TIPO_DHCP[$r]}" != "0" ]]; then
        leer "Rango DHCP — últimos octetos separados por espacios (ej: 2 4 6 8 10)" RED_DHCP_RANGO[$r]
        leer "Tiempo default-lease en horas (ej: 3)" tmp_dl "3"
        leer "Tiempo max-lease en horas (ej: 6)" tmp_ml "6"
        RED_DHCP_TIEMPO[$r]="$((tmp_dl*3600)):$((tmp_ml*3600))"
    fi

    echo -e "  ${BOLD}¿Tiene DNS esta red?${NC}"
    echo -e "    0) Sin servidor DNS (solo /etc/hosts entre sí)"
    echo -e "    1) Slave de master"
    echo -e "    2) DDNS maestro local"
    echo -e "    3) Solo /etc/hosts (red sin DNS pero con PINGs por FQDN)"
    leer "Tipo DNS de esta red" RED_TIPO_DNS[$r] "1"
done

# ═══════════════════════════════════════════════════════════
#  PASO 3 — SERVIDOR MASTER DNS
# ═══════════════════════════════════════════════════════════
if [[ "$HAY_MASTER" == "s" ]]; then
    titulo "PASO 3 — SERVIDOR MASTER DNS"

    leer "Nombre oficial del MASTER (mayúsculas en el examen, ej: WINDOWSDNS)" MASTER_NOMBRE
    leer "Alias del MASTER [en minúsculas, ej: masterdns]" MASTER_ALIAS "masterdns"
    leer "IP del MASTER en su red principal" MASTER_IP
    leer "¿En cuántas redes tiene interfaz el MASTER?" MASTER_NUM_REDES "1"

    declare -a MASTER_IPS MASTER_REDES
    MASTER_IPS[1]="$MASTER_IP"
    for ((i=2; i<=MASTER_NUM_REDES; i++)); do
        leer "IP del MASTER en red $i" MASTER_IPS[$i]
        leer "Red $i del MASTER (3 octetos)" MASTER_REDES[$i]
    done

    leer "¿Cuántos dominios gestiona el MASTER como zona autoritaria?" MASTER_NUM_DOM "2"
    declare -a MASTER_DOM_NOMBRE MASTER_DOM_RED

    for ((d=1; d<=MASTER_NUM_DOM; d++)); do
        echo; sep2; echo -e "  ${BOLD}Dominio $d del MASTER${NC}"
        leer "Nombre del dominio (ej: nombre.com)" MASTER_DOM_NOMBRE[$d]
        leer "Red de este dominio (3 octetos, ej: 10.12.14)" MASTER_DOM_RED[$d]
        leer "IP del SLAVE que recibirá transferencias de zona (Enter si no hay)" MASTER_DOM_SLAVE_IP[$d] ""
    done
fi

# ═══════════════════════════════════════════════════════════
#  PASO 4 — SERVIDOR SLAVE DNS
# ═══════════════════════════════════════════════════════════
if [[ "$HAY_SLAVE" == "s" ]]; then
    titulo "PASO 4 — SERVIDOR SLAVE DNS"

    leer "Nombre oficial del SLAVE (ej: UBUNTUDNS)" SLAVE_NOMBRE
    leer "Alias del SLAVE [ej: slavedns]" SLAVE_ALIAS "slavedns"
    leer "¿Cuántas interfaces/IPs tiene el SLAVE?" SLAVE_NUM_IFACES "1"

    declare -a SLAVE_IPS SLAVE_IFACES_RED
    for ((i=1; i<=SLAVE_NUM_IFACES; i++)); do
        leer "IP del SLAVE en la interfaz $i" SLAVE_IPS[$i]
        leer "Red de esa interfaz (3 octetos)" SLAVE_IFACES_RED[$i]
    done

    leer "IP del MASTER (desde donde recibe transferencias)" SLAVE_MASTER_IP
    leer "¿Cuántos dominios recibe por transferencia de zona?" SLAVE_NUM_DOM "2"

    declare -a SLAVE_DOM SLAVE_DOM_RED
    for ((d=1; d<=SLAVE_NUM_DOM; d++)); do
        echo; sep2; echo -e "  ${BOLD}Dominio esclavo $d${NC}"
        leer "Nombre del dominio (ej: nombre.com)" SLAVE_DOM[$d]
        leer "Red del dominio (3 octetos)" SLAVE_DOM_RED[$d]
    done

    leer "Carpeta donde el slave guardará las zonas en /etc/bind/ [Enter=esclavos]" SLAVE_CARPETA "esclavos"
fi

# ═══════════════════════════════════════════════════════════
#  PASO 5 — SERVIDOR DDNS (Debian DHCP+DNS)
# ═══════════════════════════════════════════════════════════
if [[ "$HAY_DDNS" == "s" ]]; then
    titulo "PASO 5 — SERVIDOR DEBIAN DDNS (DHCP+DNS)"

    leer "Nombre oficial (ej: DEBIANDDNS)" DDNS_NOMBRE
    leer "Alias [ej: serverddns]" DDNS_ALIAS "serverddns"
    leer "¿Cuántas interfaces tiene el servidor DDNS?" DDNS_NUM_IFACES "1"

    declare -a DDNS_IPS DDNS_IFACES_RED DDNS_IFACES_NIC
    for ((i=1; i<=DDNS_NUM_IFACES; i++)); do
        echo; sep2; echo -e "  ${BOLD}Interfaz $i del DDNS${NC}"
        leer "IP en esta interfaz (ej: 100.102.104.250)" DDNS_IPS[$i]
        leer "Red de esta interfaz (3 octetos, ej: 100.102.104)" DDNS_IFACES_RED[$i]
        leer "Nombre de la NIC en Linux (ej: ens18)" DDNS_IFACES_NIC[$i] "ens18"
    done

    leer "Carpeta de zonas DDNS en /etc/bind/ [Enter=zonas]" DDNS_CARPETA_ZONAS "zonas"
    leer "Hostname del servidor DDNS en DNS (ej: serverddns)" DDNS_HOSTNAME_DNS "serverddns"

    leer "¿Cuántas zonas DDNS (dominios que gestiona con allow-update)?" DDNS_NUM_ZONAS "2"
    declare -a DDNS_DOM DDNS_DOM_RED

    for ((d=1; d<=DDNS_NUM_ZONAS; d++)); do
        echo; sep2; echo -e "  ${BOLD}Zona DDNS $d${NC}"
        leer "Nombre del dominio DDNS (ej: apellido1.sys)" DDNS_DOM[$d]
        leer "Red de este dominio (3 octetos)" DDNS_DOM_RED[$d]
        leer "IP del DDNS en esa red" DDNS_DOM_IP[$d]
    done

    # ¿Es también esclavo del master?
    leer "¿Este servidor DDNS también es SLAVE de alguna zona del MASTER? (s/n)" DDNS_ES_SLAVE "s"
    if [[ "$DDNS_ES_SLAVE" == "s" ]]; then
        leer "IP del MASTER del que es esclavo" DDNS_SLAVE_MASTER_IP
        leer "¿Cuántos dominios recibe por transferencia?" DDNS_SLAVE_NUM_DOM "0"
        declare -a DDNS_SLAVE_DOM DDNS_SLAVE_DOM_RED
        for ((d=1; d<=DDNS_SLAVE_NUM_DOM; d++)); do
            leer "Dominio esclavo $d" DDNS_SLAVE_DOM[$d]
            leer "Red del dominio esclavo $d" DDNS_SLAVE_DOM_RED[$d]
        done
    fi

    # Interfaces DHCP
    leer "¿Cuántas redes sirve DHCP el servidor DDNS?" DDNS_NUM_DHCP "2"
    declare -a DDNS_DHCP_RED DDNS_DHCP_GW DDNS_DHCP_RANGO DDNS_DHCP_DL DDNS_DHCP_ML DDNS_DHCP_DOM

    for ((d=1; d<=DDNS_NUM_DHCP; d++)); do
        echo; sep2; echo -e "  ${BOLD}Subred DHCP $d${NC}"
        leer "Red (3 octetos, ej: 100.102.104)" DDNS_DHCP_RED[$d]
        leer "Dominio de esta red (ej: apellido1.sys)" DDNS_DHCP_DOM[$d]
        leer "Gateway (último octeto, ej: 254)" DDNS_DHCP_GW[$d] "254"
        leer "IPs del rango (últimos octetos, separados por espacios, ej: 2 4 6 8 10)" DDNS_DHCP_RANGO[$d]
        leer "default-lease-time en horas" tmp_dl "3"
        leer "max-lease-time en horas" tmp_ml "6"
        DDNS_DHCP_DL[$d]=$((tmp_dl*3600))
        DDNS_DHCP_ML[$d]=$((tmp_ml*3600))
    done

    leer "Interfaz(es) DHCP (separadas por espacio, ej: ens19 ens20)" DDNS_IFACES_DHCP
fi

# ═══════════════════════════════════════════════════════════
#  PASO 6 — MÁQUINAS CLIENTE / HOSTS
# ═══════════════════════════════════════════════════════════
titulo "PASO 6 — MÁQUINAS (clientes, servidores sin DNS, etc.)"
echo -e "  Aquí describes TODAS las máquinas del escenario."
echo -e "  Incluye servidores DNS también si aparecen en zonas."
echo

leer "¿Cuántas máquinas hay en total (sin contar servidores DNS ya descritos)?" NUM_MAQUINAS

declare -a MAQ_NOMBRE MAQ_ALIAS MAQ_SO MAQ_NUM_IFACES
declare -a MAQ_IPS MAQ_REDS MAQ_NICS

for ((m=1; m<=NUM_MAQUINAS; m++)); do
    echo; sep2; echo -e "  ${BOLD}MÁQUINA $m${NC}"
    leer "Nombre oficial (ej: DEBIANT)" MAQ_NOMBRE[$m]
    leer "Alias [ej: debiant, enter si no tiene]" MAQ_ALIAS[$m] ""
    echo -e "    SO: 1=Debian  2=Ubuntu  3=Windows"
    leer "Sistema operativo" MAQ_SO[$m] "1"
    leer "¿Cuántas interfaces de red tiene?" MAQ_NUM_IFACES[$m] "1"

    for ((i=1; i<=MAQ_NUM_IFACES[$m]; i++)); do
        echo -e "    ${CYAN}Interfaz $i:${NC}"
        leer "  IP (ej: 10.12.14.30)" tmp_ip
        leer "  Red (3 octetos, ej: 10.12.14)" tmp_red
        leer "  Dominio de esta red (ej: nombre.com)" tmp_dom
        leer "  Nombre de la NIC [ej: ens18]" tmp_nic "ens18"
        leer "  ¿IP fija o DHCP? (fija/dhcp)" tmp_tipo "fija"
        MAQ_IPS[$m,i]="$tmp_ip"
        MAQ_REDS[$m,i]="$tmp_red"
        MAQ_DOMS[$m,i]="$tmp_dom"
        MAQ_NICS[$m,i]="$tmp_nic"
        MAQ_TIPO_IP[$m,i]="$tmp_tipo"
        leer "  Gateway (solo último octeto) [Enter si no aplica]" MAQ_GW[$m,i] ""
        leer "  DNS primario que usará" MAQ_DNS1[$m,i] ""
        leer "  DNS secundario [Enter si no hay]" MAQ_DNS2[$m,i] ""
    done
done

# ═══════════════════════════════════════════════════════════
#  PASO 7 — REDES SIN DNS (/etc/hosts)
# ═══════════════════════════════════════════════════════════
titulo "PASO 7 — REDES SIN SERVIDOR DNS"
echo -e "  Las redes sin DNS necesitan /etc/hosts para resolver FQDNs."
echo
leer "¿Cuántas redes NO tienen servidor DNS (requieren /etc/hosts)?" NUM_REDES_SIN_DNS "0"

declare -a RSINDNS_RED RSINDNS_DOM RSINDNS_MAQUINAS
for ((r=1; r<=NUM_REDES_SIN_DNS; r++)); do
    echo; sep2; echo -e "  ${BOLD}Red sin DNS $r${NC}"
    leer "Red (3 octetos)" RSINDNS_RED[$r]
    leer "Dominio de esa red (ej: nombreap1ap2.net)" RSINDNS_DOM[$r]
    leer "¿Cuántas máquinas tienen IP en esa red?" RSINDNS_NUM_MAQ[$r] "2"
    for ((m2=1; m2<=RSINDNS_NUM_MAQ[$r]; m2++)); do
        leer "  Hostname de la máquina $m2 en esa red" RSINDNS_MAQ_HOST[$r,$m2]
        leer "  IP de esa máquina en esa red" RSINDNS_MAQ_IP[$r,$m2]
    done
done

# ═══════════════════════════════════════════════════════════
#  GENERACIÓN DE FICHEROS
# ═══════════════════════════════════════════════════════════
titulo "GENERANDO FICHEROS DE CONFIGURACIÓN..."

# ─── MASTER DNS ──────────────────────────────────────────────
if [[ "$HAY_MASTER" == "s" ]]; then
    MDIR="$DIR/MASTER_${MASTER_NOMBRE}"
    mkdir -p "$MDIR/zonas"
    info "Generando MASTER DNS: $MASTER_NOMBRE"

    # named.conf.local
    echo "" > "$MDIR/named.conf.local"
    for ((d=1; d<=MASTER_NUM_DOM; d++)); do
        DOM="${MASTER_DOM_NOMBRE[$d]}"
        RED="${MASTER_DOM_RED[$d]}"
        INV=$(red_a_inversa "$RED")
        SLAVE_IP="${MASTER_DOM_SLAVE_IP[$d]}"
        ALLOW_TRANSFER=""
        [[ -n "$SLAVE_IP" ]] && ALLOW_TRANSFER="    allow-transfer { $SLAVE_IP; };
    also-notify { $SLAVE_IP; };
    notify yes;"

        cat >> "$MDIR/named.conf.local" << EOF

// ── Dominio: $DOM ──
zone "$DOM" {
    type master;
    file "/etc/bind/zonas/db.$DOM";
    allow-query { any; };
$ALLOW_TRANSFER
};

zone "$INV.in-addr.arpa" {
    type master;
    file "/etc/bind/zonas/db.$RED";
    allow-query { any; };
$ALLOW_TRANSFER
};
EOF

        # Zona directa
        ZD="$MDIR/zonas/db.$DOM"
        echo "" > "$ZD"
        zona_soa_directa "$ZD" "$DOM" "$MASTER_ALIAS" "admin"
        # Añadir el master mismo
        echo >> "$ZD"; echo "; ── Hosts ──" >> "$ZD"
        zona_a "$ZD" "$MASTER_NOMBRE" "$MASTER_ALIAS" "$MASTER_IP" "$DOM"

        # Zona inversa
        ZI="$MDIR/zonas/db.$RED"
        echo "" > "$ZI"
        zona_soa_inversa "$ZI" "$INV" "$MASTER_ALIAS" "$DOM" "admin"
        echo >> "$ZI"; echo "; ── PTR ──" >> "$ZI"
        zona_ptr "$ZI" "$MASTER_IP" "$MASTER_NOMBRE.$DOM"
    done

    # Script instalador para Windows (solo informativo)
    if [[ "$MASTER_TIPO" == "1" ]]; then
        cat > "$MDIR/INSTRUCCIONES_WINDOWS.txt" << EOF
== CONFIGURACIÓN WINDOWS DNS ==

1. Abrir DNS Manager (dnsmgmt.msc)
2. Crear zona directa primaria para cada dominio:
EOF
        for ((d=1; d<=MASTER_NUM_DOM; d++)); do
            echo "   - ${MASTER_DOM_NOMBRE[$d]}" >> "$MDIR/INSTRUCCIONES_WINDOWS.txt"
        done
        cat >> "$MDIR/INSTRUCCIONES_WINDOWS.txt" << EOF

3. En cada zona añadir:
   - Registro A: $MASTER_NOMBRE → $MASTER_IP
   - CNAME: $MASTER_ALIAS → $MASTER_NOMBRE

4. Crear zona inversa para cada red.

5. Permitir transferencias de zona al SLAVE: ${SLAVE_IPS[1]:-"IP_SLAVE"}
   (Propiedades de la zona → Transferencias de zona)

6. Registros en /etc/hosts de Windows si necesario:
   C:\Windows\System32\drivers\etc\hosts
EOF
    else
        # Instalador Linux para master
        cat > "$MDIR/instalar_master.sh" << 'EOFM'
#!/bin/bash
cd "$(dirname "$0")" || exit 1
[ "$EUID" -ne 0 ] && echo "Usa: sudo ./instalar_master.sh" && exit 1

echo "1. Copiando named.conf.local..."
cp named.conf.local /etc/bind/

echo "2. Creando carpeta de zonas..."
mkdir -p /etc/bind/zonas
cp zonas/* /etc/bind/zonas/

echo "3. Ajustando permisos..."
chown -R bind:bind /etc/bind/zonas
chmod -R 775 /etc/bind/zonas

echo "4. Reiniciando BIND9..."
systemctl restart bind9
systemctl status bind9 --no-pager | grep Active
EOFM
        chmod +x "$MDIR/instalar_master.sh"
    fi

    ok "MASTER generado en $MDIR/"
fi

# ─── SLAVE DNS ───────────────────────────────────────────────
if [[ "$HAY_SLAVE" == "s" ]]; then
    SDIR="$DIR/SLAVE_${SLAVE_NOMBRE}"
    mkdir -p "$SDIR"
    info "Generando SLAVE DNS: $SLAVE_NOMBRE"

    echo "" > "$SDIR/named.conf.local"
    for ((d=1; d<=SLAVE_NUM_DOM; d++)); do
        DOM="${SLAVE_DOM[$d]}"
        RED="${SLAVE_DOM_RED[$d]}"
        INV=$(red_a_inversa "$RED")
        cat >> "$SDIR/named.conf.local" << EOF

// ── Zona esclava: $DOM ──
zone "$DOM" {
    type slave;
    file "/etc/bind/$SLAVE_CARPETA/db.$DOM";
    masters { $SLAVE_MASTER_IP; };
    allow-query { any; };
};

zone "$INV.in-addr.arpa" {
    type slave;
    file "/etc/bind/$SLAVE_CARPETA/db.$RED";
    masters { $SLAVE_MASTER_IP; };
    allow-query { any; };
};
EOF
    done

    cat > "$SDIR/instalar_slave.sh" << EOFS
#!/bin/bash
cd "\$(dirname "\$0")" || exit 1
[ "\$EUID" -ne 0 ] && echo "Usa: sudo ./instalar_slave.sh" && exit 1

CARPETA="$SLAVE_CARPETA"

echo "1. Limpiando CRLF..."
sed -i 's/\r//g' named.conf.local 2>/dev/null || true

echo "2. Copiando named.conf.local..."
cp named.conf.local /etc/bind/

echo "3. Creando carpeta de zonas esclavas..."
mkdir -p /etc/bind/\$CARPETA
chown -R bind:bind /etc/bind/\$CARPETA
chmod -R 775 /etc/bind/\$CARPETA

echo "4. AppArmor: añadiendo permiso a la carpeta..."
grep -q "$SLAVE_CARPETA" /etc/apparmor.d/local/usr.sbin.named 2>/dev/null || \
  echo "/etc/bind/$SLAVE_CARPETA/** rw," >> /etc/apparmor.d/local/usr.sbin.named
systemctl reload apparmor

echo "5. Reiniciando BIND9..."
systemctl restart bind9
systemctl status bind9 --no-pager | grep Active

echo
echo "Comprueba que los ficheros de zona se han recibido:"
echo "  ls /etc/bind/\$CARPETA/"
EOFS
    chmod +x "$SDIR/instalar_slave.sh"
    ok "SLAVE generado en $SDIR/"
fi

# ─── SERVIDOR DDNS ───────────────────────────────────────────
if [[ "$HAY_DDNS" == "s" ]]; then
    DDIR="$DIR/DDNS_${DDNS_NOMBRE}"
    mkdir -p "$DDIR/$DDNS_CARPETA_ZONAS"
    info "Generando DDNS: $DDNS_NOMBRE"

    # named.conf.local
    echo "" > "$DDIR/named.conf.local"

    # Zonas DDNS maestras
    for ((d=1; d<=DDNS_NUM_ZONAS; d++)); do
        DOM="${DDNS_DOM[$d]}"
        RED="${DDNS_DOM_RED[$d]}"
        IP_LOCAL="${DDNS_DOM_IP[$d]}"
        INV=$(red_a_inversa "$RED")

        cat >> "$DDIR/named.conf.local" << EOF

// ── Zona DDNS maestra: $DOM ──
zone "$DOM" {
    type master;
    file "/etc/bind/$DDNS_CARPETA_ZONAS/db.$DOM";
    allow-update { key "rndc-key"; };
    allow-query { any; };
};

zone "$INV.in-addr.arpa" {
    type master;
    file "/etc/bind/$DDNS_CARPETA_ZONAS/db.$RED";
    allow-update { key "rndc-key"; };
    allow-query { any; };
};
EOF

        # Zona directa DDNS
        ZD="$DDIR/$DDNS_CARPETA_ZONAS/db.$DOM"
        echo "" > "$ZD"
        zona_soa_directa "$ZD" "$DOM" "$DDNS_HOSTNAME_DNS" "admin"
        echo >> "$ZD"; echo "; ── Servidor DDNS ──" >> "$ZD"
        zona_a "$ZD" "$DDNS_NOMBRE" "$DDNS_ALIAS" "$IP_LOCAL" "$DOM"

        # Zona inversa DDNS
        ZI="$DDIR/$DDNS_CARPETA_ZONAS/db.$RED"
        echo "" > "$ZI"
        zona_soa_inversa "$ZI" "$INV" "$DDNS_HOSTNAME_DNS" "$DOM" "admin"
        echo >> "$ZI"; echo "; ── PTR ──" >> "$ZI"
        zona_ptr "$ZI" "$IP_LOCAL" "$DDNS_NOMBRE.$DOM"
    done

    # Si también es esclavo
    if [[ "$DDNS_ES_SLAVE" == "s" && "$DDNS_SLAVE_NUM_DOM" -gt 0 ]]; then
        DDNS_ESC_CARPETA="${SLAVE_CARPETA:-esclavos}"
        echo "/etc/bind/$DDNS_ESC_CARPETA/** rw," > "$DDIR/apparmor.named.generado"
        for ((d=1; d<=DDNS_SLAVE_NUM_DOM; d++)); do
            DOM="${DDNS_SLAVE_DOM[$d]}"
            RED="${DDNS_SLAVE_DOM_RED[$d]}"
            INV=$(red_a_inversa "$RED")
            cat >> "$DDIR/named.conf.local" << EOF

// ── Zona esclava (de master): $DOM ──
zone "$DOM" {
    type slave;
    file "/etc/bind/$DDNS_ESC_CARPETA/db.$DOM";
    masters { $DDNS_SLAVE_MASTER_IP; };
    allow-query { any; };
};

zone "$INV.in-addr.arpa" {
    type slave;
    file "/etc/bind/$DDNS_ESC_CARPETA/db.$RED";
    masters { $DDNS_SLAVE_MASTER_IP; };
    allow-query { any; };
};
EOF
        done
    fi

    # Zonas DHCP en named.conf.local
    for ((d=1; d<=DDNS_NUM_DHCP; d++)); do
        echo "/etc/bind/$DDNS_CARPETA_ZONAS/** rw," > "$DDIR/apparmor.named.generado"
    done

    # dhcpd.conf
    DHCP_FILE="$DDIR/dhcpd.conf"
    cat > "$DHCP_FILE" << EOF
# dhcpd.conf — Generado para $DDNS_NOMBRE
ddns-updates on;
ddns-update-style interim;
update-static-leases on;
ignore client-updates;
authoritative;
include "/etc/dhcp/rndc.key";

EOF
    # Declaraciones de zona DDNS para el DHCP
    for ((d=1; d<=DDNS_NUM_ZONAS; d++)); do
        DOM="${DDNS_DOM[$d]}"
        RED="${DDNS_DOM_RED[$d]}"
        INV=$(red_a_inversa "$RED")
        cat >> "$DHCP_FILE" << EOF
zone $DOM. { primary 127.0.0.1; key rndc-key; }
zone $INV.in-addr.arpa. { primary 127.0.0.1; key rndc-key; }
EOF
    done

    echo "" >> "$DHCP_FILE"

    # Subredes DHCP
    for ((d=1; d<=DDNS_NUM_DHCP; d++)); do
        RED_DHCP="${DDNS_DHCP_RED[$d]}"
        GW_DHCP="${DDNS_DHCP_GW[$d]}"
        DOM_DHCP="${DDNS_DHCP_DOM[$d]}"
        DL="${DDNS_DHCP_DL[$d]}"
        ML="${DDNS_DHCP_ML[$d]}"
        MASCARA=$(cidr_a_mascara 24)
        BROADCAST="$RED_DHCP.255"
        GW_IP="$RED_DHCP.$GW_DHCP"
        DNS_IP="${DDNS_DOM_IP[$d]:-${DDNS_IPS[1]}}"

        # Calcular rango (pares de octetos consecutivos)
        RANGO="${DDNS_DHCP_RANGO[$d]}"
        OCTETOS=($RANGO)
        RANGE_START="$RED_DHCP.${OCTETOS[0]}"
        RANGE_END="$RED_DHCP.${OCTETOS[${#OCTETOS[@]}-1]}"

        # Detectar si el rango tiene huecos (no consecutivos)
        RANGOS_STR="    range $RANGE_START $RANGE_END;"
        # Si el primer y último octeto no son consecutivos, comprobar huecos
        IDX_START=${OCTETOS[0]}
        IDX_END=${OCTETOS[${#OCTETOS[@]}-1]}
        if [[ $((IDX_END - IDX_START + 1)) -ne ${#OCTETOS[@]} ]]; then
            # Hay huecos — generar ranges individuales
            RANGOS_STR=""
            for OCT in "${OCTETOS[@]}"; do
                RANGOS_STR+="    range $RED_DHCP.$OCT $RED_DHCP.$OCT;"$'\n'
            done
        fi

        cat >> "$DHCP_FILE" << EOF

subnet $RED_DHCP.0 netmask $MASCARA {
$RANGOS_STR
    option domain-name          "$DOM_DHCP";
    option domain-name-servers  $DNS_IP;
    option routers              $GW_IP;
    option broadcast-address    $BROADCAST;
    default-lease-time          $DL;
    max-lease-time              $ML;
}
EOF
    done

    # isc-dhcp-server
    cat > "$DDIR/isc-dhcp-server" << EOF
INTERFACESv4="$DDNS_IFACES_DHCP"
INTERFACESv6=""
EOF

    # Script instalador DDNS
    cat > "$DDIR/instalar_ddns.sh" << EOFD
#!/bin/bash
cd "\$(dirname "\$0")" || exit 1
[ "\$EUID" -ne 0 ] && echo "Usa: sudo ./instalar_ddns.sh" && exit 1

CARPETA_ZONAS="$DDNS_CARPETA_ZONAS"
ESC_CARPETA="${SLAVE_CARPETA:-esclavos}"

echo "0. Limpiando CRLF..."
sed -i 's/\r//g' named.conf.local dhcpd.conf isc-dhcp-server 2>/dev/null || true

echo "1. Creando carpetas de zonas..."
mkdir -p /etc/bind/\$CARPETA_ZONAS
cp \$CARPETA_ZONAS/* /etc/bind/\$CARPETA_ZONAS/ 2>/dev/null || true
chown -R bind:bind /etc/bind/\$CARPETA_ZONAS
chmod -R 775 /etc/bind/\$CARPETA_ZONAS

if [ -f apparmor.named.generado ]; then
    echo "1b. Creando carpeta de esclavos..."
    mkdir -p /etc/bind/\$ESC_CARPETA
    chown -R bind:bind /etc/bind/\$ESC_CARPETA
    chmod -R 775 /etc/bind/\$ESC_CARPETA
fi

echo "2. Copiando named.conf.local..."
cp named.conf.local /etc/bind/

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

echo "4. Copiando dhcpd.conf..."
cp dhcpd.conf /etc/dhcp/dhcpd.conf
cp isc-dhcp-server /etc/default/isc-dhcp-server

echo "5. AppArmor..."
[ -f apparmor.named.generado ] && cp apparmor.named.generado /etc/apparmor.d/local/usr.sbin.named
systemctl reload apparmor

echo "6. Reiniciando servicios..."
systemctl restart bind9
systemctl restart isc-dhcp-server

echo "────────────────────────────────────"
systemctl status bind9 --no-pager | grep Active
systemctl status isc-dhcp-server --no-pager | grep Active
echo "────────────────────────────────────"
echo
echo "Comprueba ficheros .jnl (aparecerán al llegar un cliente DHCP):"
echo "  ls /etc/bind/\$CARPETA_ZONAS/*.jnl"
EOFD
    chmod +x "$DDIR/instalar_ddns.sh"
    ok "DDNS generado en $DDIR/"
fi

# ─── /etc/hosts para redes sin DNS ───────────────────────────
for ((r=1; r<=NUM_REDES_SIN_DNS; r++)); do
    RED="${RSINDNS_RED[$r]}"
    DOM="${RSINDNS_DOM[$r]}"
    HFILE="$DIR/hosts_red_${RED//\./_}_${DOM}"
    echo "# /etc/hosts para la red $RED ($DOM)" > "$HFILE"
    echo "# Añadir en CADA máquina de esta red:" >> "$HFILE"
    echo "" >> "$HFILE"
    echo "127.0.0.1    localhost" >> "$HFILE"
    echo "" >> "$HFILE"
    for ((m2=1; m2<=RSINDNS_NUM_MAQ[$r]; m2++)); do
        HOST="${RSINDNS_MAQ_HOST[$r,$m2]}"
        IP="${RSINDNS_MAQ_IP[$r,$m2]}"
        FQDN="${HOST}.${DOM}"
        printf "%-18s %s %s\n" "$IP" "$FQDN" "$HOST" >> "$HFILE"
    done
    ok "/etc/hosts para red sin DNS ($DOM) → $HFILE"
done

# ─── Configuración de red para cada máquina ──────────────────
for ((m=1; m<=NUM_MAQUINAS; m++)); do
    MNOMBRE="${MAQ_NOMBRE[$m]}"
    MSO="${MAQ_SO[$m]}"
    MDIR2="$DIR/CLIENTE_${MNOMBRE}"
    mkdir -p "$MDIR2"

    SCRIPT_CLI="$MDIR2/configurar_red.sh"
    cat > "$SCRIPT_CLI" << EOFM
#!/bin/bash
# Configuración de red para: $MNOMBRE
[ "\$EUID" -ne 0 ] && echo "Usa: sudo ./configurar_red.sh" && exit 1

echo "== Configurando $MNOMBRE =="

# 1. Hostname
hostnamectl set-hostname "${MNOMBRE,,}"
EOFM

    for ((i=1; i<=MAQ_NUM_IFACES[$m]; i++)); do
        MNIC="${MAQ_NICS[$m,i]}"
        MIP="${MAQ_IPS[$m,i]}"
        MRED="${MAQ_REDS[$m,i]}"
        MDOM="${MAQ_DOMS[$m,i]}"
        MGW="${MAQ_GW[$m,i]}"
        MDNS1="${MAQ_DNS1[$m,i]}"
        MDNS2="${MAQ_DNS2[$m,i]}"
        MTIPO="${MAQ_TIPO_IP[$m,i]}"
        MMASK=$(cidr_a_mascara 24)
        MCIDR=24

        if [[ "$MSO" == "2" ]]; then
            # Ubuntu — Netplan
            NETPLAN_FILE="$MDIR2/01-netcfg_iface${i}.yaml"
            if [[ "$MTIPO" == "fija" ]]; then
                DNS_LIST="[${MDNS1}$([ -n "$MDNS2" ] && echo ", $MDNS2")]"
                cat > "$NETPLAN_FILE" << EOFN
network:
  version: 2
  renderer: networkd
  ethernets:
    $MNIC:
      dhcp4: no
      addresses:
        - $MIP/$MCIDR
      routes:
        - to: default
          via: $MRED.${MGW:-254}
      nameservers:
        addresses: $DNS_LIST
        search: [$MDOM]
EOFN
            else
                cat > "$NETPLAN_FILE" << EOFN
network:
  version: 2
  renderer: networkd
  ethernets:
    $MNIC:
      dhcp4: yes
      nameservers:
        addresses: [${MDNS1}$([ -n "$MDNS2" ] && echo ", $MDNS2")]
        search: [$MDOM]
EOFN
            fi
            cat >> "$SCRIPT_CLI" << EOFM2
cp 01-netcfg_iface${i}.yaml /etc/netplan/01-netcfg.yaml
chmod 600 /etc/netplan/01-netcfg.yaml
EOFM2

        else
            # Debian — /etc/network/interfaces
            IFACES_SNIPPET="$MDIR2/interfaces_iface${i}.txt"
            if [[ "$MTIPO" == "fija" ]]; then
                cat > "$IFACES_SNIPPET" << EOFI
auto $MNIC
iface $MNIC inet static
    address $MIP
    netmask $MMASK
    gateway $MRED.${MGW:-254}
    dns-nameservers $MDNS1${MDNS2:+ $MDNS2}
    dns-search $MDOM
EOFI
            else
                cat > "$IFACES_SNIPPET" << EOFI
auto $MNIC
iface $MNIC inet dhcp
EOFI
            fi
            cat >> "$SCRIPT_CLI" << EOFM2
# Añadir interfaz $MNIC a /etc/network/interfaces
sed -i "/^auto $MNIC/,/^\$/d" /etc/network/interfaces 2>/dev/null || true
cat interfaces_iface${i}.txt >> /etc/network/interfaces
EOFM2
        fi

        # resolv.conf para Debian
        if [[ "$MSO" != "2" ]]; then
            RESOLV="$MDIR2/resolv_iface${i}.conf"
            cat > "$RESOLV" << EOFR
domain $MDOM
search $MDOM
nameserver $MDNS1
$([ -n "$MDNS2" ] && echo "nameserver $MDNS2")
EOFR
            cat >> "$SCRIPT_CLI" << EOFM2
# resolv.conf
if [ -L /etc/resolv.conf ]; then rm -f /etc/resolv.conf; fi
chattr -i /etc/resolv.conf 2>/dev/null || true
cp resolv_iface${i}.conf /etc/resolv.conf
EOFM2
        fi
    done

    # Reinicio de red al final
    if [[ "$MSO" == "2" ]]; then
        echo "netplan apply" >> "$SCRIPT_CLI"
    else
        for ((i=1; i<=MAQ_NUM_IFACES[$m]; i++)); do
            MNIC="${MAQ_NICS[$m,i]}"
            echo "ifdown $MNIC 2>/dev/null; ifup $MNIC 2>/dev/null" >> "$SCRIPT_CLI"
        done
    fi

    cat >> "$SCRIPT_CLI" << EOFM2

echo
echo "== VERIFICACIÓN $MNOMBRE =="
hostname -f
ip a
echo "DNS: ${MAQ_DNS1[$m,1]}"
EOFM2
    chmod +x "$SCRIPT_CLI"

    # /etc/hosts básico
    HOSTS_CLI="$MDIR2/etc_hosts.txt"
    echo "# Añadir a /etc/hosts de $MNOMBRE" > "$HOSTS_CLI"
    echo "127.0.0.1    localhost" >> "$HOSTS_CLI"
    FQDN_M="${MNOMBRE,,}.${MAQ_DOMS[$m,1]}"
    echo "127.0.1.1    $FQDN_M ${MNOMBRE,,}" >> "$HOSTS_CLI"

    ok "Cliente $MNOMBRE generado en $MDIR2/"
done

# ─── Comandos DIG/NSLOOKUP de verificación ───────────────────
DIGFILE="$DIR/COMANDOS_VERIFICACION.txt"
cat > "$DIGFILE" << 'EOF'
══════════════════════════════════════════════════════
  COMANDOS DE VERIFICACIÓN (DIG / NSLOOKUP)
══════════════════════════════════════════════════════

DIG — Resolución directa:
  dig FQDN @IP_SERVIDOR_DNS

DIG — Resolución inversa:
  dig -x IP_MAQUINA @IP_SERVIDOR_DNS

DIG — Consulta de alias CNAME:
  dig ALIAS.DOMINIO @IP_SERVIDOR_DNS

NSLOOKUP (Windows) — Directo:
  nslookup FQDN IP_SERVIDOR_DNS

NSLOOKUP (Windows) — Inverso:
  nslookup IP_MAQUINA IP_SERVIDOR_DNS

Ver ficheros .jnl (DDNS):
  ls /etc/bind/zonas/*.jnl
  watch -n1 ls /etc/bind/zonas/

Ver leases DHCP (servidor):
  cat /var/lib/dhcp/dhcpd.leases

Renovar IP en cliente Linux:
  dhclient -r ens18 && dhclient ens18 && ip a

Ver transferencia de zonas (slave):
  ls /etc/bind/esclavos/
  systemctl status bind9

EOF

ok "Comandos de verificación → $DIGFILE"

# ─── Resumen final ───────────────────────────────────────────
titulo "FICHEROS GENERADOS"
echo
ls -1 "$DIR/"
echo
sep2
echo -e "  ${BOLD}Directorio de salida:${NC} $DIR/"
echo
echo -e "  ${BOLD}Pasos para el examen:${NC}"
echo -e "  1. Copia la carpeta del servidor a cada máquina"
echo -e "     (USB, SCP, carpeta compartida, etc.)"
echo -e "  2. Ejecuta el script instalar_*.sh o configurar_red.sh"
echo -e "     con sudo en cada máquina"
echo -e "  3. Comprueba con los comandos de COMANDOS_VERIFICACION.txt"
echo
sep
