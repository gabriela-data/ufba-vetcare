#!/usr/bin/env fish

# ============================================================
# VetCare (UFBA) - cria board, labels, milestones, issues e
# sub-issues a partir dos documentos de arquitetura.
#
#   labels -> milestones -> board (Projects v2) -> 77 issues
#   (20 principais + 57 sub-issues vinculadas)
#
# Uso:   fish criar-projeto-vetcare.fish        (pede confirmacao)
#        fish criar-projeto-vetcare.fish -y     (sem confirmacao)
#
# Requisitos:
#   - gh logado, com escopo "project":  gh auth refresh -s project
#   - acesso de ESCRITA no repositorio (peca ao dono para te
#     adicionar como colaborador)
#
# Pode ser re-executado: issues com o mesmo titulo sao puladas.
# ============================================================

# ---------- CONFIGURACAO ----------
set -g REPO_OWNER "LucioCarvalhoDev"
set -g REPO "ufba-vetcare"
# Dono do board. "@me" = sua conta (o repo e de outra pessoa, entao
# o board fica com voce). Se voce for o dono do repo, tanto faz.
set -g PROJECT_OWNER "@me"
set -g PROJECT_TITLE "VetCare - Board de Arquitetura"

# ---------- CORES (globais, para as funcoes enxergarem) ----------
set -g GREEN (set_color green)
set -g BLUE (set_color blue)
set -g YELLOW (set_color yellow)
set -g RED (set_color red)
set -g NC (set_color normal)
set -g FALHAS 0
set -g CRITICOS

# Logs vao para stderr; so o numero da issue vai para stdout,
# assim "set P1 (criar ...)" captura apenas o numero.
function info;  echo "$BLUE$argv$NC" >&2; end
function ok;    echo "$GREEN$argv$NC" >&2; end
function warn;  echo "$YELLOW$argv$NC" >&2; end
function erro;  echo "$RED$argv$NC" >&2; end

# ---------- VERIFICACOES ----------
if not type -q gh
    erro "GitHub CLI (gh) nao instalado."
    exit 1
end

if not gh auth status >/dev/null 2>&1
    erro "Voce nao esta logada no gh. Rode: gh auth login"
    exit 1
end

if not gh project list --owner $PROJECT_OWNER --limit 1 >/dev/null 2>&1
    erro "Falta o escopo 'project'. Rode: gh auth refresh -s project"
    exit 1
end

set -l push (gh api repos/$REPO_OWNER/$REPO --jq .permissions.push 2>/dev/null)
if test "$push" != true
    erro "Sem permissao de escrita em $REPO_OWNER/$REPO (ou repositorio nao encontrado)."
    erro "Peca ao dono para te adicionar como colaborador."
    exit 1
end

info "============================================"
info "  VetCare: $REPO_OWNER/$REPO"
info "  Board em: $PROJECT_OWNER"
info "============================================"

if not contains -- -y $argv
    read -l -P "Isso vai criar ~77 issues no repositorio. Continuar? [s/N] " resp
    if not string match -qi s -- $resp
        echo "Cancelado."
        exit 0
    end
end

# ============================================================
# FUNCOES AUXILIARES
# ============================================================

# corpo "descricao" "criterio 1" "criterio 2" ...
function corpo --argument-names desc
    set -e argv[1]
    if test -n "$desc"
        printf '%s\n' "## Descrição" "$desc" ""
    end
    printf '%s\n' "## Critérios de aceite"
    for i in $argv
        printf '%s\n' "- [ ] $i"
    end
end

# Vincula filha a pai (com retry: o GitHub demora a indexar a issue nova)
function vincular --argument-names parent num
    sleep 1
    set -l child_id ""
    for t in 1 2 3 4 5
        set child_id (gh api repos/$REPO_OWNER/$REPO/issues/$num --jq .id 2>/dev/null)
        test -n "$child_id"; and break
        sleep 2
    end

    if test -z "$child_id"
        warn "     nao consegui obter o ID de #$num"
        return 1
    end

    for t in 1 2 3 4 5
        if gh api repos/$REPO_OWNER/$REPO/issues/$parent/sub_issues \
                -X POST -F sub_issue_id=$child_id >/dev/null 2>&1
            ok "     vinculada a #$parent"
            return 0
        end
        warn "     retry $t para vincular..."
        sleep 3
    end

    warn "     vincule manualmente: #$num -> #$parent"
    return 1
end

# criar TITULO LABELS MILESTONE PAI(ou "") CORPO   ->  imprime o numero
function criar --argument-names titulo labels milestone parent body
    info "  -> $titulo"

    # Ja existe? (permite re-executar o script)
    set -l idx (contains -i -- "$titulo" $EXIST_TITLES)
    if test -n "$idx"
        set -l n $EXIST_NUMS[$idx]
        warn "     ja existe: #$n (pulada)"
        echo $n
        return 0
    end

    set -l saida (gh issue create \
        --repo $REPO_OWNER/$REPO \
        --title "$titulo" \
        --body "$body" \
        --label "$labels" \
        --milestone "$milestone" 2>&1)

    set -l url (string match -r 'https://github\.com/\S+/issues/\d+' -- $saida)[1]

    if test -z "$url"
        erro "     ERRO: $saida"
        set -g FALHAS (math $FALHAS + 1)
        return 1
    end

    set -l num (string replace -r '.*/' '' -- $url)
    ok "     criada: #$num"

    if not gh project item-add $PROJECT_NUMBER --owner $PROJECT_OWNER --url $url >/dev/null 2>&1
        warn "     nao consegui adicionar ao board"
        set -g FALHAS (math $FALHAS + 1)
    end

    if test -n "$parent"
        vincular $parent $num; or set -g FALHAS (math $FALHAS + 1)
    end

    sleep 1 # evita rate limit secundario do GitHub
    echo $num
end

# Cria sub-issues de componentes a partir de registros
#   "nome|descricao|requisitos|caracteristicas|S ou N (critico)"
function criar_componentes --argument-names parent
    set -e argv[1]
    for r in $argv
        set -l f (string split "|" -- $r)
        set -l labels "componente,arquitetura,prioridade-media"
        if test "$f[5]" = S
            set labels "componente,arquitetura,critico,prioridade-alta"
            set -ga CRITICOS $f[1]
        end
        set -l d (string join \n -- "$f[2]" "" \
            "**Requisitos relacionados:** $f[3]" "" \
            "**Características arquiteturais:** $f[4]" "" \
            "> Texto originalmente gerado por IA: conferir e corrigir." | string collect)
        set -l b (corpo "$d" \
            "Responsabilidades conferidas contra o documento de requisitos" \
            "Requisitos relacionados conferidos" \
            "Características arquiteturais conferidas" \
            "Pacote correto na árvore de pacotes do README" \
            "Texto revisado e corrigido pela equipe" | string collect)
        criar "[COMP] $f[1]" $labels $M3 $parent "$b" >/dev/null
    end
end

# ============================================================
# 1. LABELS  (nome:cor:descricao)
# ============================================================
info "\n[1/4] Labels"
for l in \
    "arquitetura:1d76db:Arquitetura de software" \
    "adr:5319e7:Architecture Decision Record" \
    "componente:0e8a16:Componente candidato" \
    "uml:d876e3:Diagramas UML" \
    "prototipo:fbca04:Prototipo no Figma" \
    "docs:0075ca:Documentacao" \
    "revisao:e99695:Revisao / correcao" \
    "critico:b60205:Top 30% componentes mais criticos" \
    "etapa-2:0052cc:Etapa II do trabalho" \
    "prioridade-alta:b60205:Prioridade alta" \
    "prioridade-media:ff9f1c:Prioridade media" \
    "prioridade-baixa:c2e0c6:Prioridade baixa"
    set -l p (string split ":" -- $l)
    gh label create $p[1] --repo $REPO_OWNER/$REPO --color $p[2] --description $p[3] --force >/dev/null 2>&1
    and ok "  $p[1]"
    or warn "  falhou: $p[1]"
end

# ============================================================
# 2. MILESTONES (uma por fase)
# ============================================================
info "\n[2/4] Milestones"
set -g M1 "Fase 1 — Características Arquiteturais"
set -g M2 "Fase 2 — ADRs"
set -g M3 "Fase 3 — Componentes Candidatos"
set -g M4 "Fase 4 — Diagramas UML"
set -g M5 "Fase 5 — Protótipo"
set -g M6 "Fase 6 — Documentação e Entrega"
set -g M7 "Fase 7 — Etapa II (Componentes Críticos)"
for m in $M1 $M2 $M3 $M4 $M5 $M6 $M7
    gh api repos/$REPO_OWNER/$REPO/milestones -f title="$m" >/dev/null 2>&1 # 422 = ja existe
    ok "  $m"
end

# ============================================================
# 3. BOARD (GitHub Projects v2)
# ============================================================
info "\n[3/4] Board"
set -g PROJECT_NUMBER (gh project list --owner $PROJECT_OWNER --limit 100 --format json \
    --jq ".projects[] | select(.title==\"$PROJECT_TITLE\") | .number" 2>/dev/null)[1]

if test -z "$PROJECT_NUMBER"
    set -g PROJECT_NUMBER (gh project create --owner $PROJECT_OWNER --title "$PROJECT_TITLE" \
        --format json --jq .number 2>/dev/null)
    if test -z "$PROJECT_NUMBER"
        erro "  falha ao criar o board"
        exit 1
    end
    ok "  board criado: #$PROJECT_NUMBER"
else
    ok "  board existente reutilizado: #$PROJECT_NUMBER"
end
gh project link $PROJECT_NUMBER --owner $PROJECT_OWNER --repo $REPO_OWNER/$REPO >/dev/null 2>&1
or warn "  nao liguei o board ao repo (ok: as issues entram no board do mesmo jeito)"

# ============================================================
# 4. ISSUES
# ============================================================
info "\n[4/4] Issues"

# Issues que ja existem (para pular em re-execucoes)
set -g EXIST_NUMS
set -g EXIST_TITLES
for line in (gh issue list --repo $REPO_OWNER/$REPO --state all --limit 1000 \
        --json number,title --jq '.[] | "\(.number)\t\(.title)"' 2>/dev/null)
    set -l f (string split \t -- $line)
    set -ga EXIST_NUMS $f[1]
    set -ga EXIST_TITLES $f[2]
end

# ------------------------------------------------------------
# FASE 1 - CARACTERISTICAS ARQUITETURAIS
# ------------------------------------------------------------
warn "\nFase 1 - Características arquiteturais"

set P1 (criar "[ARQ] Levantar características arquiteturais relevantes" \
    "arquitetura,docs,prioridade-alta" $M1 "" \
    (corpo "Lista de características arquiteturais relevantes para o VetCare, cada uma com breve justificativa (1–2 parágrafos) de sua importância para o sistema." \
        "Cinco características listadas: Segurança, Disponibilidade e Estabilidade, Usabilidade, Desempenho, Manutenibilidade" \
        "Cada uma com justificativa de 1–2 parágrafos" \
        "Justificativas ligadas aos requisitos e ao contexto da clínica" \
        "Texto revisado (ortografia e coesão)" | string collect))

for r in \
    "Segurança|Dados pessoais de tutores, informações clínicas, prontuários, prescrições e dados financeiros; perfis de acesso (Administrador, Recepcionista, Veterinário); LGPD." \
    "Disponibilidade e Estabilidade|Sistema disponível durante todo o expediente e resistente à corrupção de dados; redundância, tratamento de falhas e feedback ao usuário; ex.: ações do cliente com ID único reenviadas até confirmação." \
    "Usabilidade|Recepcionistas e veterinários precisam de rapidez e segurança; alta rotatividade de funcionários; navegação simples e consistente." \
    "Desempenho|Consulta de agendas, prontuários, atendimentos e pagamentos em tempo adequado; evitar filas e erros operacionais." \
    "Manutenibilidade|Evolução com novas funcionalidades (relatórios, integrações, regras de vacinação); modularidade, baixo acoplamento, alta coesão e documentação."
    set -l f (string split "|" -- $r)
    criar "[ARQ] Justificar: $f[1]" "arquitetura,docs,prioridade-media" $M1 $P1 \
        (corpo "Pontos-chave: $f[2]" \
            "Justificativa de 1–2 parágrafos redigida" \
            "Ligação com os requisitos do VetCare explicitada" \
            "Revisada pela equipe" | string collect) >/dev/null
end

set P2 (criar "[ARQ] Selecionar e justificar o Top 4 de características" \
    "arquitetura,docs,prioridade-alta" $M1 "" \
    (corpo "Escolher as 4 características prioritárias, cada uma com Decisão e Justificativa." \
        "Top 4 definido: Segurança, Disponibilidade e Estabilidade, Desempenho, Manutenibilidade" \
        "Cada item com Decisão + Justificativa" \
        "Top 4 refletido no README" | string collect))

for r in \
    "Segurança|Tratar como característica prioritária: autenticação, autorização e proteção de dados na base da arquitetura, não como camada adicional." \
    "Disponibilidade e Estabilidade|Projetar para permanecer disponível e estável durante o horário de funcionamento: tolerância a falhas, monitoramento e recuperação rápida." \
    "Desempenho|Operações críticas (agenda, prontuário, atendimento, pagamento) respondem em tempo adequado ao fluxo de atendimento." \
    "Manutenibilidade|Arquitetura favorece a evolução do sistema com baixo impacto nos componentes existentes."
    set -l f (string split "|" -- $r)
    criar "[ARQ] Top 4: $f[1]" "arquitetura,docs,prioridade-alta" $M1 $P2 \
        (corpo "Decisão: $f[2]" \
            "Decisão escrita em uma frase" \
            "Justificativa ligada ao documento de requisitos" \
            "Revisada pela equipe" | string collect) >/dev/null
end

criar "[ARQ] Documentar por que Usabilidade ficou fora do Top 4" \
    "arquitetura,docs,prioridade-media" $M1 $P2 \
    (corpo "A Usabilidade é considerada relevante (item 1), mas não está entre as 4 prioritárias. O README a cita apenas como 'outra característica considerada'." \
        "Critério de priorização explicitado" \
        "Justificativa da exclusão registrada" \
        "Equipe de acordo com a decisão" | string collect) >/dev/null

# ------------------------------------------------------------
# FASE 2 - ADRs
# ------------------------------------------------------------
warn "\nFase 2 - ADRs"

set P3 (criar "[ADR] Registrar decisões arquiteturais (ADR-001 a ADR-004)" \
    "adr,docs,prioridade-alta" $M2 "" \
    (corpo "Uma ADR para cada característica do Top 4, em documents/adrs/. Status atual de todas: Proposto (aguardando validação da equipe), 29/09/2026." \
        "ADR-001 a ADR-004 em documents/adrs/" \
        "Todas com Contexto, Decisão, Consequências (positivas e negativas) e Alternativas Consideradas" \
        "Status atualizado após validação" \
        "Índice de ADRs criado" | string collect))

for r in \
    "ADR-001|Segurança|Davi, Gabriela|Autenticação obrigatória, RBAC, proteção de dados em trânsito e em repouso e auditoria de acessos e alterações relevantes." \
    "ADR-002|Disponibilidade e Estabilidade|Davi|Tolerância a falhas, monitoramento, recuperação rápida, backups regulares, evitar pontos únicos de falha e redundância nos componentes críticos." \
    "ADR-003|Desempenho|Davi|Consultas otimizadas, índices adequados, cache para dados frequentes e processamento assíncrono para tarefas não bloqueantes." \
    "ADR-004|Manutenibilidade|Davi|Modularização por domínio, baixo acoplamento, alta coesão, interfaces bem definidas entre módulos e testes automatizados."
    set -l f (string split "|" -- $r)
    set -l d (string join \n -- \
        "**Responsáveis:** $f[3]" "" \
        "**Decisão:** $f[4]" | string collect)
    criar "[ADR] Revisar e validar $f[1]: $f[2]" "adr,docs,prioridade-alta" $M2 $P3 \
        (corpo "$d" \
            "Arquivo em documents/adrs/" \
            "Seções: Contexto, Decisão, Consequências (positivas e negativas), Alternativas Consideradas" \
            "Decisão coerente com a lista de componentes" \
            "Validada pela equipe: status muda de Proposto para Aceito" | string collect) >/dev/null
end

criar "[ADR] Criar índice de ADRs" "adr,docs,prioridade-baixa" $M2 $P3 \
    (corpo "Índice para facilitar a navegação entre as decisões." \
        "documents/adrs/README.md com tabela: ADR, título, status, data, responsáveis" \
        "Índice linkado no README principal" | string collect) >/dev/null

# ------------------------------------------------------------
# FASE 3 - COMPONENTES CANDIDATOS
# ------------------------------------------------------------
warn "\nFase 3 - Componentes candidatos"

set P4 (criar "[COMP] Camada de Apresentação e Acesso" "componente,arquitetura,prioridade-alta" $M3 "" \
    (corpo "Seção 3.1 da lista de componentes. Pacote no README: apresentacao (ui, gateway)." \
        "Todos os componentes do grupo descritos (responsabilidade, REQs, características)" \
        "Texto gerado por IA revisado e corrigido" \
        "Consistente com a árvore de pacotes do README" | string collect))
criar_componentes $P4 \
    "Módulo de Interface do Usuário (UI)|Responsável pela interação com recepcionistas, veterinários e administradores. Apresenta telas de cadastro, agenda, prontuário, prescrição, pagamentos, dashboard e relatórios. Deve aplicar boas práticas de usabilidade e respeitar as permissões do usuário logado.|REQ 01–17 (interface para todos)|Usabilidade, Segurança, Desempenho|N" \
    "API Gateway / Camada de API|Ponto único de entrada para as requisições do front-end. Responsável por roteamento, autenticação inicial, limitação de taxa (rate limiting) e padronização das respostas. Evita exposição direta dos serviços internos.|Suporte a todos os REQs|Segurança, Manutenibilidade, Desempenho|S"

set P5 (criar "[COMP] Segurança e Acesso" "componente,arquitetura,prioridade-alta" $M3 "" \
    (corpo "Seção 3.2 da lista de componentes. Pacote no README: seguranca (autenticacao, autorizacao, auditoria)." \
        "Todos os componentes do grupo descritos (responsabilidade, REQs, características)" \
        "Texto gerado por IA revisado e corrigido" \
        "Consistente com a árvore de pacotes do README" | string collect))
criar_componentes $P5 \
    "Serviço de Autenticação|Responsável por validar credenciais e emitir tokens de acesso. Suporta login de usuários cadastrados e controle de sessão.|REQ 02 (Autenticar Usuário)|Segurança, Disponibilidade|S" \
    "Serviço de Autorização (RBAC)|Verifica se o usuário autenticado tem permissão para executar cada operação, com base em papéis (Administrador, Recepcionista, Veterinário). Restringe acesso a informações clínicas e dados pessoais.|REQ 01, REQ 02, REQ 04–14|Segurança, Manutenibilidade|S" \
    "Módulo de Recuperação de Senha|Gera e valida tokens de recuperação, envia instruções ao usuário e permite a redefinição de senha.|REQ 03 (Recuperar Senha)|Segurança, Disponibilidade|N" \
    "Módulo de Auditoria|Registra acessos, alterações e operações relevantes, permitindo rastrear quem fez o quê e quando. Apoia conformidade legal e investigação de incidentes.|Transversal (Segurança)|Segurança, Confiabilidade, Auditabilidade|S"

set P6 (criar "[COMP] Domínio de Cadastros" "componente,arquitetura,prioridade-media" $M3 "" \
    (corpo "Seção 3.3 da lista de componentes. Pacote no README: cadastros (usuarios, tutores, animais, veterinarios)." \
        "Todos os componentes do grupo descritos (responsabilidade, REQs, características)" \
        "Texto gerado por IA revisado e corrigido" \
        "Consistente com a árvore de pacotes do README" | string collect))
criar_componentes $P6 \
    "Módulo de Usuários|Inclusão, alteração, exclusão e consulta de usuários do sistema, incluindo associação a papéis de acesso.|REQ 01 (Manter Usuário)|Segurança, Manutenibilidade|N" \
    "Módulo de Tutores|Cadastro, alteração, consulta e exclusão dos dados dos tutores responsáveis pelos animais.|REQ 04 (Manter Tutor)|Manutenibilidade, Segurança|N" \
    "Módulo de Animais|Cadastro, alteração, consulta e exclusão dos animais, sempre associados a um tutor. Armazena nome, espécie, raça, sexo e data de nascimento.|REQ 05 (Manter Animal)|Manutenibilidade, Desempenho|N" \
    "Módulo de Veterinários|Cadastro e gerenciamento dos profissionais veterinários da clínica.|REQ 06 (Manter Veterinário)|Manutenibilidade, Segurança|N"

set P7 (criar "[COMP] Domínio Clínico" "componente,arquitetura,prioridade-alta" $M3 "" \
    (corpo "Seção 3.4 da lista de componentes. Pacote no README: clinico (agenda, atendimentos, prontuarios, vacinacao, prescricoes)." \
        "Todos os componentes do grupo descritos (responsabilidade, REQs, características)" \
        "Texto gerado por IA revisado e corrigido" \
        "Consistente com a árvore de pacotes do README" | string collect))
criar_componentes $P7 \
    "Módulo de Agenda/Consultas|Agendamento, cancelamento e consulta de consultas, relacionando animal, tutor, veterinário, data e horário. Permite visualização por dia, semana ou profissional.|REQ 07 (Agendar Consulta), REQ 08 (Cancelar Consulta), REQ 09 (Consultar Agenda)|Desempenho, Disponibilidade, Manutenibilidade|S" \
    "Módulo de Atendimentos|Registra as informações do atendimento realizado pelo veterinário, servindo de base para o prontuário.|REQ 10 (Registrar Atendimento)|Segurança, Confiabilidade, Manutenibilidade|N" \
    "Módulo de Prontuários|Mantém o histórico de atendimentos do animal, incluindo diagnósticos, observações, procedimentos realizados e prescrições.|REQ 11 (Manter Prontuário)|Segurança, Desempenho, Confiabilidade|S" \
    "Módulo de Vacinação|Registro das vacinas aplicadas, incluindo tipo, data de aplicação e previsão da próxima dose.|REQ 12 (Registrar Vacinação)|Manutenibilidade, Segurança|N" \
    "Módulo de Prescrições|Permite que o veterinário registre e disponibilize prescrições relacionadas ao atendimento.|REQ 13 (Emitir Prescrição)|Segurança, Manutenibilidade|N"

set P8 (criar "[COMP] Domínio Financeiro e Gerencial" "componente,arquitetura,prioridade-media" $M3 "" \
    (corpo "Seção 3.5 da lista de componentes. Pacote no README: financeiro (pagamentos, dashboard, relatorios)." \
        "Todos os componentes do grupo descritos (responsabilidade, REQs, características)" \
        "Texto gerado por IA revisado e corrigido" \
        "Consistente com a árvore de pacotes do README" | string collect))
criar_componentes $P8 \
    "Módulo de Pagamentos|Registro dos pagamentos relacionados às consultas e procedimentos realizados.|REQ 14 (Registrar Pagamento)|Segurança, Confiabilidade, Manutenibilidade|S" \
    "Módulo de Dashboard Financeiro|Apresenta informações financeiras da clínica, incluindo valores recebidos e quantidade de atendimentos em determinado período.|REQ 15 (Dashboard Financeiro)|Desempenho, Manutenibilidade|N" \
    "Módulo de Relatórios Gerenciais|Geração de relatórios sobre atendimentos, animais cadastrados, consultas e dados financeiros.|REQ 17 (Gerar Relatórios Gerenciais)|Desempenho, Manutenibilidade|N"

set P9 (criar "[COMP] Serviços de Suporte" "componente,arquitetura,prioridade-alta" $M3 "" \
    (corpo "Seção 3.6 da lista de componentes. Pacotes no README: suporte (notificacoes, cache, fila, backup, monitoramento) e persistencia (banco_dados)." \
        "Todos os componentes do grupo descritos (responsabilidade, REQs, características)" \
        "Texto gerado por IA revisado e corrigido" \
        "Consistente com a árvore de pacotes do README" | string collect))
criar_componentes $P9 \
    "Serviço de Notificações|Envia notificações ao tutor sobre consultas agendadas e datas previstas para vacinação.|REQ 16 (Notificar Tutor)|Disponibilidade, Desempenho (processamento assíncrono)|N" \
    "Serviço de Cache|Armazena temporariamente dados frequentemente acessados (ex.: agenda do dia, prontuários recentes) para reduzir tempo de resposta e carga no banco.|Transversal|Desempenho, Disponibilidade|N" \
    "Serviço de Processamento Assíncrono (Fila)|Executa tarefas não bloqueantes, como envio de notificações, geração de relatórios e rotinas de backup, sem impactar a experiência do usuário.|REQ 16, REQ 17|Desempenho, Disponibilidade, Manutenibilidade|S" \
    "Banco de Dados|Persistência de todos os dados do sistema: usuários, tutores, animais, consultas, prontuários, pagamentos etc. Deve garantir integridade, consistência e disponibilidade.|Todos|Segurança, Disponibilidade, Confiabilidade, Desempenho|S" \
    "Serviço de Backup e Recuperação|Realiza cópias de segurança periódicas e permite recuperação em caso de falhas.|Transversal|Disponibilidade, Estabilidade, Confiabilidade|N" \
    "Serviço de Monitoramento e Logs|Acompanha o funcionamento do sistema, registra eventos, mede desempenho e emite alertas em caso de falhas ou comportamento anômalo.|Transversal|Disponibilidade, Desempenho, Manutenibilidade|N"

# --- Revisao da lista (o texto original foi marcado como "gerado por IA, verificar e corrigir") ---
set P10 (criar "[REVISÃO] Verificar e corrigir a lista de componentes" \
    "revisao,componente,prioridade-alta" $M3 "" \
    (corpo "A lista de componentes foi marcada como resposta de IA a verificar e corrigir. As sub-issues abaixo cobrem inconsistências encontradas entre o documento e o README." \
        "Todas as sub-issues concluídas" \
        "Documento de componentes e README consistentes entre si" | string collect))

criar "[REVISÃO] Conferir componentes x requisitos (REQ 01–17)" \
    "revisao,componente,prioridade-alta" $M3 $P10 \
    (corpo "Garantir que a lista cobre todos os requisitos e que os REQs citados em cada componente estão corretos." \
        "Cada REQ 01–17 atendido por ao menos um componente" \
        "Componentes sem REQ próprio justificados (transversais)" \
        "Campo 'Requisitos relacionados' corrigido onde necessário" | string collect) >/dev/null

criar "[REVISÃO] Alinhar características usadas nos componentes" \
    "revisao,arquitetura,prioridade-media" $M3 $P10 \
    (corpo "Os componentes citam Confiabilidade e Auditabilidade, que não estão entre as 5 características do item 1 do documento (o README as menciona só como 'outras consideradas')." \
        "Decidir: incluir Confiabilidade e Auditabilidade na lista do item 1, ou renomear nos componentes" \
        "Documento e README usando o mesmo conjunto de características" | string collect) >/dev/null

criar "[REVISÃO] Alinhar agrupamento dos componentes com a árvore de pacotes" \
    "revisao,componente,prioridade-media" $M3 $P10 \
    (corpo "Divergências entre o documento e a árvore de pacotes do README: (1) o Módulo de Recuperação de Senha não aparece na árvore (seguranca tem só autenticacao, autorizacao e auditoria); (2) o Banco de Dados está em 'Serviços de Suporte' no documento, mas no pacote persistencia no README." \
        "Decidir onde fica Recuperação de Senha (pacote próprio ou dentro de autenticacao)" \
        "Decidir o agrupamento do Banco de Dados" \
        "Documento, README e diagrama de pacotes consistentes" | string collect) >/dev/null

criar "[REVISÃO] Fechar a lista do Top 30% mais críticos" \
    "revisao,critico,prioridade-alta" $M3 $P10 \
    (corpo "O documento sugere 7 componentes críticos (7 de 24 ≈ 29%, abaixo de 30%); o README lista 9 (37,5%). Esta automação usa a lista do README (os 9 marcados com a label 'critico')." \
        "Mínimo de 8 componentes críticos (30% de 24 = 7,2)" \
        "Lista única, igual no documento e no README" \
        "Critério de criticidade explicado (ligado às características do Top 4)" \
        "Labels 'critico' e sub-issues da Fase 7 ajustadas se a lista mudar" | string collect) >/dev/null

# ------------------------------------------------------------
# FASE 4 - DIAGRAMAS UML
# ------------------------------------------------------------
warn "\nFase 4 - Diagramas UML"

criar "[UML] Diagrama de Pacotes" "uml,docs,prioridade-alta" $M4 "" \
    (corpo "Diagrama visual da arquitetura de pacotes e dependências do sistema." \
        "Diagrama reflete a árvore de pacotes do README" \
        "Dependências entre pacotes representadas" \
        "Sem dependências cíclicas entre os domínios" \
        "Link correto publicado no README" | string collect) >/dev/null

criar "[UML] Diagrama de Classes" "uml,docs,prioridade-alta" $M4 "" \
    (corpo "Modelagem das entidades e relacionamentos do domínio. O link no README ainda é um placeholder." \
        "Entidades cobrindo os requisitos (ex.: Usuário, Tutor, Animal, Veterinário, Consulta, Atendimento, Prontuário, Vacina, Prescrição, Pagamento)" \
        "Atributos, relacionamentos e cardinalidades" \
        "Link real no README" | string collect) >/dev/null

criar "[UML] Diagrama de Sequência (fluxos críticos)" "uml,docs,prioridade-media" $M4 "" \
    (corpo "Interações entre os componentes nos fluxos críticos. O link no README ainda é um placeholder." \
        "Fluxos: autenticação, agendamento de consulta, registro de atendimento/prontuário e pagamento" \
        "Interações passando por API Gateway, Autenticação e Autorização" \
        "Link real no README" | string collect) >/dev/null

# ------------------------------------------------------------
# FASE 5 - PROTOTIPO
# ------------------------------------------------------------
warn "\nFase 5 - Protótipo"

set P12 (criar "[PROTÓTIPO] Protótipo navegável no Figma" "prototipo,prioridade-media" $M5 "" \
    (corpo "Interfaces visuais para validar usabilidade antes da implementação." \
        "Protótipo navegável publicado no Figma" \
        "Link compartilhado com a equipe e no README" | string collect))

criar "[PROTÓTIPO] Tela de Login" "prototipo,prioridade-alta" $M5 $P12 \
    (corpo "Autenticação com e-mail/usuário e senha, com opção de recuperação de senha." \
        "Tela desenhada no Figma" \
        "Fluxo de recuperação de senha ligado" \
        "Print adicionado ao README" | string collect) >/dev/null

criar "[PROTÓTIPO] Tela de Cadastro de Usuário" "prototipo,prioridade-alta" $M5 $P12 \
    (corpo "Inclusão de usuários com nome, e-mail, perfil de acesso (Administrador, Recepcionista, Veterinário) e senha." \
        "Tela desenhada no Figma" \
        "Seleção de perfil de acesso presente" \
        "Print adicionado ao README" | string collect) >/dev/null

criar "[PROTÓTIPO] Telas adicionais (Agenda, Prontuário, Financeiro)" "prototipo,prioridade-baixa" $M5 $P12 \
    (corpo "Opcional, conforme o avanço do projeto (o README prevê essas telas)." \
        "Agenda" "Prontuário" "Financeiro" \
        "Prints adicionados ao README" | string collect) >/dev/null

criar "[PROTÓTIPO] Publicar link do protótipo e trocar imagens placeholder" "prototipo,docs,prioridade-media" $M5 $P12 \
    (corpo "O README ainda usa link e imagens de exemplo." \
        "Link real do Figma no README" \
        "Imagens placeholder substituídas por prints reais" | string collect) >/dev/null

# ------------------------------------------------------------
# FASE 6 - DOCUMENTACAO E ENTREGA
# ------------------------------------------------------------
warn "\nFase 6 - Documentação e entrega"

criar "[DOCS] Preencher a seção Equipe do README" "docs,prioridade-media" $M6 "" \
    (corpo "A tabela ainda tem placeholders ([Nome 1], @usuario1...)." \
        "Nomes, usuários do GitHub e funções preenchidos" \
        "Todos os integrantes listados" | string collect) >/dev/null

criar "[DOCS] Substituir links e prints placeholder do README" "docs,prioridade-media" $M6 "" \
    (corpo "Há links de exemplo (Figma, Diagrama de Classes, Diagrama de Sequência) e uma nota de instruções no fim da tabela de artefatos." \
        "Todos os links reais" \
        "Notas de instrução removidas" | string collect) >/dev/null

criar "[DOCS] Criar o arquivo LICENSE (MIT)" "docs,prioridade-baixa" $M6 "" \
    (corpo "O README declara licença MIT e aponta para um arquivo LICENSE, mas o repositório hoje só tem README.md e documents/adrs." \
        "Arquivo LICENSE (MIT) criado na raiz" \
        "Link do README funcionando" | string collect) >/dev/null

criar "[DOCS] Linkar ADRs e board no README" "docs,adr,prioridade-baixa" $M6 "" \
    (corpo "Facilitar a navegação para as decisões e o acompanhamento do trabalho." \
        "Seção sobre ADRs com links" \
        "Link do board do projeto" | string collect) >/dev/null

criar "[DOCS] Revisão final e entrega do Trabalho I (Etapa I)" "docs,prioridade-alta" $M6 "" \
    (corpo "Trabalho I – Arquitetura do Sistema VetCare (MATA62, UFBA)." \
        "Todos os artefatos citados no README acessíveis" \
        "Revisão ortográfica de todos os documentos" \
        "Lista do Top 30% consistente em todos os lugares" \
        "Entrega feita pelo canal definido pela professora" | string collect) >/dev/null

# ------------------------------------------------------------
# FASE 7 - ETAPA II (COMPONENTES CRITICOS)
# ------------------------------------------------------------
warn "\nFase 7 - Etapa II"

set P13 (criar "[ETAPA 2] Diagrama de componentes e especificação interna dos críticos" \
    "etapa-2,arquitetura,prioridade-alta" $M7 "" \
    (corpo "Próxima etapa: diagrama de componentes com especificação interna de pelo menos 30% dos componentes mais críticos." \
        "Diagrama de componentes completo" \
        "Pelo menos 30% dos componentes (mínimo 8 de 24) especificados internamente" \
        "Consistente com a árvore de pacotes e com as ADRs" | string collect))

criar "[ETAPA 2] Diagrama de componentes" "etapa-2,uml,prioridade-alta" $M7 $P13 \
    (corpo "Visão geral dos componentes e de suas dependências." \
        "Todos os componentes e pacotes representados" \
        "Interfaces e dependências entre componentes" \
        "Componentes críticos destacados" \
        "Consistente com o diagrama de pacotes" | string collect) >/dev/null

for c in $CRITICOS
    criar "[ETAPA 2] Especificação interna: $c" "etapa-2,critico,arquitetura,prioridade-alta" $M7 $P13 \
        (corpo "Detalhar a estrutura interna do componente crítico: $c." \
            "Responsabilidades e limites do componente definidos" \
            "Interfaces providas e requeridas especificadas" \
            "Estrutura interna (subcomponentes ou classes) desenhada" \
            "Táticas para as características do Top 4 aplicáveis explicitadas" \
            "Dependências consistentes com o diagrama de componentes" \
            "Revisada pela equipe" | string collect) >/dev/null
end

# ============================================================
# RESUMO
# ============================================================
set -l board_url (gh project view $PROJECT_NUMBER --owner $PROJECT_OWNER --format json --jq .url 2>/dev/null)

echo
ok "============================================"
ok "  Projeto VetCare criado!"
ok "============================================"
echo
info "Board:  $board_url"
info "Issues: https://github.com/$REPO_OWNER/$REPO/issues"
info "Componentes críticos (label 'critico'): "(count $CRITICOS)
if test $FALHAS -gt 0
    warn "Atenção: $FALHAS operação(ões) falharam (veja os avisos acima)."
    warn "Rode o script de novo: o que já existe é pulado."
end
echo