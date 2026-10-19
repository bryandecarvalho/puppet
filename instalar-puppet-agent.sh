#!/usr/bin/env bash
#
# instalar-puppet-agent.sh
# Automatiza o procedimento "Puppet Agent - Instalação (NOVO)".
#
# Uso:
#   sudo ./instalar-puppet-agent.sh [-s servidor] [-w segundos] [-h]
#
#   -s  Hostname do Puppet Master (padrão: puppetmaster02.centralserver.com.br)
#   -w  Aguarda até N segundos o certificado ser assinado no Master
#       (padrão: 0 = não aguarda, só gera a requisição)
#   -h  Ajuda
#
set -uo pipefail

PUPPET_SERVER="puppetmaster02.centralserver.com.br"
WAIT_CERT=0
CENTOS7_RELEASE_RPM="https://yum.puppetlabs.com/puppet5/puppet5-release-el-7.noarch.rpm"

# AlmaLinux 10: o documento remete a um procedimento separado
# ("Instalação do Puppet Core 8"). Informe aqui a URL do RPM de repositório
# usado nesse procedimento, ou exporte a variável antes de rodar o script.
EL10_RELEASE_RPM="${EL10_RELEASE_RPM:-}"

log()  { echo -e "\e[1;34m[INFO]\e[0m $*"; }
warn() { echo -e "\e[1;33m[AVISO]\e[0m $*"; }
die()  { echo -e "\e[1;31m[ERRO]\e[0m $*" >&2; exit 1; }

usage() { sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while getopts ":s:w:h" opt; do
  case "$opt" in
    s) PUPPET_SERVER="$OPTARG" ;;
    w) WAIT_CERT="$OPTARG" ;;
    h) usage ;;
    *) die "Opção inválida. Use -h para ajuda." ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Execute como root (sudo)."
[[ "$WAIT_CERT" =~ ^[0-9]+$ ]] || die "-w precisa ser um número de segundos."
[[ -r /etc/os-release ]] || die "/etc/os-release não encontrado; distro não suportada."

. /etc/os-release
OS_ID="${ID:-}"
OS_LIKE="${ID_LIKE:-}"
OS_MAJOR="${VERSION_ID%%.*}"

# ---------- Detecta a família ----------
if [[ "$OS_ID" == "centos" && "$OS_MAJOR" == "7" ]]; then
  FAMILY="centos7"
elif [[ "$OS_ID" == "almalinux" && "$OS_MAJOR" == "10" ]]; then
  FAMILY="alma10"
elif [[ "$OS_ID" =~ ^(rhel|rocky|almalinux|ol|fedora|centos)$ || "$OS_LIKE" =~ (rhel|fedora) ]]; then
  FAMILY="redhat"
elif [[ "$OS_ID" =~ ^(debian|ubuntu)$ || "$OS_LIKE" =~ debian ]]; then
  FAMILY="debian"
else
  die "Distribuição não suportada: ${PRETTY_NAME:-$OS_ID}"
fi
log "Sistema: ${PRETTY_NAME:-$OS_ID} -> perfil '$FAMILY'"
log "Puppet Master: $PUPPET_SERVER"

# ---------- 1) Instalação ----------
case "$FAMILY" in
  redhat)
    dnf install -y puppet || die "Falha no 'dnf install puppet' (EPEL habilitado?)."
    ;;
  alma10)
    if [[ -x /opt/puppetlabs/bin/puppet ]]; then
      log "Puppet já instalado em /opt/puppetlabs; pulando instalação."
    elif [[ -n "$EL10_RELEASE_RPM" ]]; then
      dnf install -y "$EL10_RELEASE_RPM" || die "Falha ao instalar o repositório do Puppet Core 8."
      dnf install -y puppet-agent       || die "Falha ao instalar o puppet-agent."
    else
      die "AlmaLinux 10: defina EL10_RELEASE_RPM (URL do repositório do Puppet Core 8 conforme o procedimento interno) ou instale o agente antes e rode o script de novo."
    fi
    ;;
  centos7)
    rpm -q puppet5-release &>/dev/null || rpm -Uvh "$CENTOS7_RELEASE_RPM" \
      || die "Falha ao instalar o repositório puppet5."
    yum install -y puppet-agent || die "Falha no 'yum install puppet-agent'."
    ;;
  debian)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y && apt-get install -y puppet || die "Falha no 'apt install puppet'."
    ;;
esac

# Localiza o binário (AIO em /opt/puppetlabs ou pacote da distro)
if [[ -x /opt/puppetlabs/bin/puppet ]]; then
  PUPPET=/opt/puppetlabs/bin/puppet
elif command -v puppet &>/dev/null; then
  PUPPET="$(command -v puppet)"
else
  die "Binário do puppet não encontrado após a instalação."
fi
log "Binário: $PUPPET ($("$PUPPET" --version 2>/dev/null))"

# ---------- 2) Configura o servidor ----------
if [[ "$FAMILY" == "centos7" ]]; then
  CONF=/etc/puppetlabs/puppet/puppet.conf
  mkdir -p "$(dirname "$CONF")"
  touch "$CONF"
  cp -a "$CONF" "${CONF}.bak.$(date +%Y%m%d%H%M%S)"
  if grep -q '^\[main\]' "$CONF"; then
    # remove 'server =' antigo dentro do arquivo e insere logo após [main]
    sed -i '/^[[:space:]]*server[[:space:]]*=/d' "$CONF"
    sed -i "/^\[main\]/a server = ${PUPPET_SERVER}" "$CONF"
  else
    printf '[main]\nserver = %s\n\n' "$PUPPET_SERVER" | cat - "$CONF" > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"
  fi
  log "puppet.conf atualizado (backup criado ao lado)."
else
  "$PUPPET" config set server "$PUPPET_SERVER" --section main || die "Falha ao definir o server."
fi
mkdir -p /etc/puppet
log "server = $("$PUPPET" config print server --section main)"

# ---------- 3) Primeira execução / CSR ----------
CERTNAME="$("$PUPPET" config print certname)"
log "Executando 'puppet agent --test' (certname: $CERTNAME)..."
"$PUPPET" agent --test --waitforcert "$WAIT_CERT"
RC=$?
# Códigos do --test: 0 sem mudanças | 2 mudanças aplicadas | 4/6 falhas em recursos | 1 erro (ex.: certificado não assinado)
case "$RC" in
  0|2) log "Agente rodou com sucesso (rc=$RC)." ; SIGNED=1 ;;
  4|6) warn "Agente conectou, mas houve falhas em recursos (rc=$RC). Verifique a saída acima." ; SIGNED=1 ;;
  *)   warn "Certificado provavelmente ainda não assinado (rc=$RC)." ; SIGNED=0 ;;
esac

# ---------- 5) Habilita o serviço ----------
# O daemon fica tentando buscar o certificado sozinho, então pode ser
# habilitado mesmo antes da assinatura.
systemctl enable --now puppet && log "Serviço puppet habilitado e iniciado." \
  || warn "Não foi possível habilitar o serviço puppet."

# ---------- 4) Instruções para o Master ----------
if [[ "$SIGNED" -eq 0 ]]; then
  cat <<EOF

======================================================================
 Falta assinar o certificado no Puppet Master ($PUPPET_SERVER):

   puppetserver ca list
   puppetserver ca sign --certname $CERTNAME

 Depois, aqui no agente, valide com:
   $PUPPET agent --test

 (Para remover este agente do Master: puppetserver ca clean --certname $CERTNAME)
======================================================================
EOF
fi
