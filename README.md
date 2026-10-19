# instalar-puppet-agent

Script que automatiza o procedimento **"Puppet Agent - Instalação (NOVO)"**: instala o Puppet Agent, aponta para o Puppet Master, gera a requisição de certificado e habilita o serviço — detectando sozinho a distribuição Linux.

## Distribuições suportadas

| Distribuição | Perfil | Como instala |
|---|---|---|
| RHEL, Rocky, AlmaLinux (≠10), Oracle Linux, Fedora, CentOS (≠7) | `redhat` | `dnf install puppet` (requer **EPEL** habilitado) |
| AlmaLinux 10 | `alma10` | Repositório do **Puppet Core 8** via `EL10_RELEASE_RPM` + `dnf install puppet-agent` |
| CentOS 7 | `centos7` | Repositório `puppet5-release` + `yum install puppet-agent` |
| Debian, Ubuntu e derivados | `debian` | `apt-get install puppet` |

A detecção é feita por `/etc/os-release` (`ID`, `ID_LIKE` e `VERSION_ID`).

## Requisitos

- Executar como **root** (ou via `sudo`)
- `systemd`
- Acesso à internet / repositórios da distro
- Resolução de DNS e acesso na porta **8140** até o Puppet Master

## Uso rápido

```bash
git clone <url-deste-repositorio>
cd <pasta-do-repositorio>
chmod +x instalar-puppet-agent.sh
sudo ./instalar-puppet-agent.sh
```

### Opções

| Opção | Descrição | Padrão |
|---|---|---|
| `-s <host>` | Hostname do Puppet Master | `puppetmaster02.centralserver.com.br` |
| `-w <segundos>` | Aguarda até N segundos o certificado ser assinado no Master | `0` (não aguarda, só gera a requisição) |
| `-h` | Mostra a ajuda | — |

### Exemplos

```bash
# Master padrão, sem esperar assinatura
sudo ./instalar-puppet-agent.sh

# Outro Master, aguardando até 5 minutos pela assinatura do certificado
sudo ./instalar-puppet-agent.sh -s puppet.exemplo.com.br -w 300

# AlmaLinux 10: informe o RPM de repositório do Puppet Core 8
sudo EL10_RELEASE_RPM="https://<url-do-rpm>" ./instalar-puppet-agent.sh
```

## Como funciona

O script executa as etapas do procedimento na seguinte ordem:

1. **Detecção do sistema** — lê `/etc/os-release` e escolhe o perfil (`redhat`, `alma10`, `centos7` ou `debian`).
2. **Instalação** — instala o pacote adequado para o perfil. Depois localiza o binário do `puppet`, priorizando a instalação AIO em `/opt/puppetlabs/bin/puppet`.
3. **Configuração do servidor** — define `server = <Puppet Master>` na seção `[main]`:
   - **CentOS 7:** edita `/etc/puppetlabs/puppet/puppet.conf` diretamente, criando antes um backup (`puppet.conf.bak.AAAAMMDDHHMMSS`) e removendo qualquer linha `server =` antiga.
   - **Demais:** usa `puppet config set server <host> --section main`.
4. **Primeira execução (CSR)** — roda `puppet agent --test --waitforcert <N>`, que gera e envia a requisição de certificado ao Master. O código de retorno é interpretado assim:

   | Código | Significado |
   |---|---|
   | `0` | Rodou sem mudanças |
   | `2` | Rodou e aplicou mudanças |
   | `4` / `6` | Conectou, mas houve falhas em recursos |
   | outros (ex.: `1`) | Certificado provavelmente ainda não assinado |

5. **Serviço** — executa `systemctl enable --now puppet`. Isso é feito mesmo antes da assinatura, pois o daemon continua tentando buscar o certificado sozinho.
6. **Instruções para o Master** — se o certificado ainda não foi assinado, o script imprime os comandos que devem ser executados no Puppet Master.

## Assinando o certificado no Master

Se ao final aparecer o aviso de certificado pendente, no **Puppet Master** execute:

```bash
puppetserver ca list
puppetserver ca sign --certname <certname-do-agente>
```

Depois, de volta no **agente**, valide:

```bash
puppet agent --test
```

> Dica: rodando com `-w 300`, você pode assinar no Master enquanto o script espera, e ele segue sozinho após a assinatura.

## Removendo um agente do Master

```bash
puppetserver ca clean --certname <certname-do-agente>
```

## Solução de problemas

| Sintoma | Causa provável / solução |
|---|---|
| `Falha no 'dnf install puppet' (EPEL habilitado?)` | Habilite o EPEL: `dnf install -y epel-release` |
| `AlmaLinux 10: defina EL10_RELEASE_RPM...` | Exporte `EL10_RELEASE_RPM` com a URL do procedimento "Instalação do Puppet Core 8", ou instale o agente manualmente e rode o script de novo |
| `Execute como root (sudo).` | Rode com `sudo` |
| `/bin/bash^M: bad interpreter` | O arquivo foi salvo com finais de linha do Windows (CRLF). Converta com `sed -i 's/\r$//' instalar-puppet-agent.sh` |
| Certificado nunca é assinado | Confira DNS/porta 8140 até o Master e se o `certname` aparece em `puppetserver ca list` |
