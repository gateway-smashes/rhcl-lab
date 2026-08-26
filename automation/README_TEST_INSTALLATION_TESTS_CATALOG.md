# Tests catalog (`rhcl-lab-git`) — instalação

Site estático (UBI9 nginx) que lista todos os `req*/` e `req*.md` da pasta
[`tests/`](../tests/) numa landing page e renderiza os READMEs com `marked.js`
(viewer + passos pra reproduzir). É o "catálogo de testes" que o Luciano subiu —
buildado a partir do `tests/Dockerfile` deste repo.

| | Valor |
|---|---|
| Namespace | `tests` (`TESTS_CATALOG_NAMESPACE`) |
| Workload | Deployment + Service `rhcl-lab-git`, porta 8080 |
| Imagem | BuildConfig **Git** (`tests/` deste repo, Dockerfile) → ImageStream `rhcl-lab-git:latest` |
| Exposição | OpenShift Route (edge) |

## Instalar

```bash
cd automation
source scripts/cluster-env.sh
ansible-playbook playbooks/tests_catalog-install.yml          # build-from-git (default)
ansible-playbook playbooks/tests_catalog-test.yml             # valida + imprime a URL
```

Também roda no fim do `install-all.yml`. Desligar com `TESTS_CATALOG_ENABLED=false`.

## Build-from-git vs imagem pronta

| `TESTS_CATALOG_IMAGE_SOURCE` | Quando usar |
|---|---|
| `build` (default) | Builda in-cluster a partir do GitHub (`TESTS_CATALOG_GIT_URI`/`_REF`). Fiel ao que roda hoje no cluster1. Precisa de egress pro GitHub. |
| `image` | Usa imagem pronta (`TESTS_CATALOG_IMAGE` + `TESTS_CATALOG_IMAGE_PULL_SECRET`). Para clusters sem egress pro GitHub (ex.: cluster sem egress pro GitHub) — builde e publique a imagem antes. |

For a private Git repository, create a Git source secret in the catalog namespace
and point the BuildConfig at it:

```bash
oc new-project tests 2>/dev/null || true
oc -n tests create secret generic rhcl-lab-git-source \
  --type=kubernetes.io/basic-auth \
  --from-literal=username='<github-user-or-token-user>' \
  --from-literal=password='<github-token>'

TESTS_CATALOG_GIT_SOURCE_SECRET=rhcl-lab-git-source \
ansible-playbook playbooks/tests_catalog-install.yml
```

## Remover

```bash
ansible-playbook playbooks/tests_catalog-remove.yml   # remove o namespace tests inteiro
```
