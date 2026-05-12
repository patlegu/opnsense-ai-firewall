# Pourquoi ce setup NE doit PAS aller en production

Ce repo embarque délibérément un LLM dans la VM OPNsense, par
curiosité. Voici **les quatre raisons concrètes** pour lesquelles
c'est une mauvaise idée en prod, et pourquoi la "vraie" topologie
(LLM sidecar) reste préférable.

## 1. Surface d'attaque

Un firewall doit être minimaliste. Ce repo ajoute sur OPNsense :

- un binaire ELF de **8.9 MB** (`/var/llm/bin/llama-server`)
- **6 librairies partagées** (~36 MB cumulé) dont OpenBLAS (28 MB)
- **Python 3.13** (~80 MB via pkg) + son écosystème stdlib
- un service rc.d `llama` daemonisé
- un endpoint d'API REST sur `127.0.0.1:8080`

Soit ~125 MB de code et un sous-système de plus à auditer / patcher /
surveiller. Chaque CVE de llama.cpp, ggml, OpenBLAS, ou Python devient
ta CVE. Pour comparaison, OPNsense minimal = ~600 MB total.

Mitigation tentée dans ce repo : bind strict `127.0.0.1` (jamais
écouté sur WAN ni LAN), service en root sans wrapper privilégié, pas
d'API publique. **Mais** un attaquant qui obtient un local shell sur
OPNsense a tout l'attirail sous la main.

## 2. Contention CPU pendant l'inférence

Une intent admin = **~10 s d'inférence** mesurée sur `cx33` (4 vCPU
shared). Pendant ces 10 s :

- `llama-server` sature les 4 vCPU à 100 % (BLAS + matmul)
- `pf` (le firewall) continue à filtrer le trafic, mais en
  **contention** sur ces mêmes cœurs

Sur un firewall qui sert peu de trafic (lab, branch office sans
pic), ça passe. Sur un edge router qui forward 500 Mbps :

- la latence p99 du forwarding part dans le décor pendant l'inférence
- le throughput peut chuter de 20-40 % le temps de la requête
- les retransmissions TCP s'enchaînent

Mitigation possible : `cpuset` pour pinner llama-server sur un seul
cœur. Mais alors les 7-10 tok/s deviennent 2-3 tok/s → 30 s/intent.
On dégrade soit la latence pf, soit le LLM. Pas d'échappatoire CPU-only.

Cf. les mesures perf à venir dans le palier E.3 de
[`demo-results.md`](demo-results.md) — section "Mesures concrètes".

## 3. Cycle de vie incompatible

OPNsense suit FreeBSD avec un cycle de release stable (1-2 par an).
llama.cpp **bouge tous les jours** :

- breaking changes ABI/format GGUF tous les ~2 mois
- nouveaux formats de quantization (Q4_K_M devient obsolète, Q4_K_M_v2,
  etc.)
- support de nouveaux chat templates (cf. notre passage b3813 →
  b9000 pour `tools` natif)

Si tu déploies en prod aujourd'hui et que tu touches plus dans 6
mois, ton binaire FreeBSD est figé sur b9000 alors que le LoRA que
tu veux charger demain ne sera plus compatible. Ce repo a un script
qui rebuild (`scripts/build-llama-freebsd.sh`) mais ça reste **toi**
qui assumes la cadence.

Sur un sidecar VM/container, le LLM se met à jour indépendamment.
OPNsense reste OPNsense.

## 4. Audit & accountability

Les firewalls sont audités. Quand une règle change, il faut savoir
**qui** l'a écrite et **pourquoi**. Avec un LLM qui modifie
`config.xml` :

- `<modified><time></modified>` indique "modifié par root"
- aucune trace de l'intent originale qui a déclenché la modif
- pas de revue à 4 yeux (le LLM n'est pas une signature)
- en cas d'incident : "le LLM a halluciné un block sur 8.8.8.8"
  n'est pas une justification acceptable en compliance

Mitigation : on a la garde-fou `--confirm` côté agent + audit log
côté `oaf_agent.py`. Mais ça reste **opérateur**, pas un contrôle
anti-malveillant ou un audit trail légal.

L'archi sidecar permet de :

- logger l'intent originale + l'utilisateur humain qui l'a tapée
- générer la règle proposée + la faire valider par un humain via PR
- garder un audit immuable hors du firewall

## En résumé

Ce repo a **trois usages valides** :

1. **Démo pédagogique** — montrer que c'est techniquement possible.
2. **Mesure de seuils** — quantifier "à partir de quand ça casse"
   pour informer un futur produit (cf. palier E.3 perf measurements).
3. **Lab/research** — tester de nouveaux LoRA, format de prompt, ou
   patterns d'agent in-box.

Et **aucun usage en prod**. Si tu veux ce concept en vrai, regarde
[asp-forge](https://gitlab.com/llm_tests/asp-forge) ou
[purpleteam-forge](https://gitlab.com/llm_tests/purpleteam-forge) :
LLM sur sidecar VM, OPNsense vanilla, API gateway audité.
