# README — Levantar la app en Canary Release (local, Minikube)

> Este README describe los pasos para levantar el tp de *canary release* en un entorno **local** con **minikube**, usando **Argo Rollouts** para el control del rollout, **NGINX Ingress** para exponer la app y **Linkerd + SMI (TrafficSplit)** para el service mesh / split de tráfico.  
> Se asume que tienes los manifiestos `namespace.yaml`, `services.yaml`, `rollout.yaml` e `ingress.yaml` en el mismo directorio desde donde ejecutás los comandos.

---

## Resumen rápido
- Cluster local: **minikube**
- Ingress: **NGINX Ingress Controller** (addon de minikube)
- Progressive delivery: **Argo Rollouts** (controller + kubectl plugin + dashboard)
- Service mesh / traffic split: **Linkerd** + **SMI (TrafficSplit)** (Argo Rollouts manipula `TrafficSplit`)
- Host recomendado: **`canary.local`**

---

## 1) Requisitos locales (pre-requisitos)
- Docker (o el driver que uses con minikube)
- minikube
- kubectl (configurado apuntando a minikube)
- curl, tar, sudo (para algunas instalaciones)

> No se requiere construir imágenes locales porque usamos la imagen pública `argoproj/rollouts-demo:green` incluida en el manifiesto.

---

## 2) Iniciar minikube
Ejemplo recomendado (ajustá `--cpus`/`--memory` según tu máquina):

```bash
minikube start --driver=docker --cpus=2 --memory=4096
```

Habilitar NGINX Ingress (addon de minikube):

```bash
minikube addons enable ingress
```

Comprobar que el Ingress Controller esté corriendo:

```bash
kubectl get pods -n ingress-nginx
```

---

## 3) Instalar Argo Rollouts (controller + CRDs) y su plugin CLI
Instalar Argo Rollouts en el cluster (se crea el namespace `argo-rollouts`):

> Guía oficial de intsalación de Ago Rollouts: https://argoproj.github.io/argo-rollouts/installation/

```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
```

Instalar los CRDs de Argo Rollouts:

```bash
kubectl apply -k https://github.com/argoproj/argo-rollouts/manifests/crds\?ref\=stable
```

Instalar los plugins de Kubectl:

> Tener brew previamente instalado

```bash
brew install argoproj/tap/kubectl-argo-rollouts
```

---

## 4) Instalar Linkerd (control plane)

> Guía oficial de intsalación de Linkerd: https://linkerd.io/2.18/getting-started/

Instalar la CLI:

```bash
export LINKERD2_VERSION=edge-25.4.4
curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/install-edge | sh
export PATH=$HOME/.linkerd2/bin:$PATH
```
Verificar instalacion:

```bash
linkerd version
```

Instalar la API del Gateway:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
```

Valida tu clúster Kubernetes
```bash
linkerd check --pre
```

Instalar Linkerd en el cluster y validar:

```bash
linkerd install --crds | kubectl apply -f -
linkerd install --set proxyInit.runAsRoot=true | kubectl apply -f -
linkerd check
```

---

## 5) Instalar el adaptador SMI para Linkerd (soporte TrafficSplit)
Instalar la extensión SMI para Linkerd (convierte `TrafficSplit` a configuración Linkerd):

```bash
curl -sL https://linkerd.github.io/linkerd-smi/install | sh
linkerd smi install | kubectl apply -f -
```

---

## 6) Preparar y aplicar los manifiestos de la app (tus archivos)
Desde el directorio donde tengas los 4 archivos subidos:

```bash
kubectl apply -f namespace.yaml
kubectl apply -f services.yaml
kubectl apply -f rollout.yaml
kubectl apply -f ingress.yaml
```

Verificá que los recursos estén creados:

```bash
kubectl get rollouts -n canary-tp
kubectl get svc -n canary-tp
kubectl get ingress -n canary-tp
```

---

## 7) Resolver DNS local para `canary.local`
Obtené la IP de minikube e insertala en `/etc/hosts` (requiere sudo):

```bash
MINIKUBE_IP=$(minikube ip)
echo "$MINIKUBE_IP canary.local" | sudo tee -a /etc/hosts
# visitá http://canary.local
```

---

## 8) Flujo de Canary — comportamiento esperado
- El `Rollout` en `rollout.yaml` está configurado con estrategia **canary** y tiene `trafficRouting` para **NGINX** y **SMI**.
- Argo Rollouts manipulará:
  - el Ingress (NGINX) si está configurado.
  - o creará/actualizará un `TrafficSplit` (SMI) si Linkerd y SMI están disponibles.

Para forzar un nuevo deploy y lanzar un rollout (ejemplo):

```bash
kubectl argo rollouts set image demo-rollout demo=argoproj/rollouts-demo:blue -n canary-tp
```

El rollout se comportará según los `steps` y `analysis` definidos en el manifest (automático).

---

## 9) Ver el progreso del canary (UI y consola)
**Dashboard (UI):**

```bash
kubectl argo rollouts dashboard -n canary-tp
# visitá http://localhost:3100
```

**CLI:**

```bash
kubectl argo rollouts get rollout demo-rollout -n canary-tp
kubectl argo rollouts get rollout demo-rollout -n canary-tp --watch
```

**TrafficSplit (SMI):**

```bash
kubectl get trafficsplit -n canary-tp
kubectl describe trafficsplit <nombre> -n canary-tp
```

---

## 10) Probar la app (requests desde host)
```bash
for i in {1..30}; do curl -sS http://canary.local/ | head -n 5; echo; done
```

---

## 11) Limpieza
```bash
kubectl delete -f ingress.yaml
kubectl delete -f rollout.yaml
kubectl delete -f services.yaml
kubectl delete -f namespace.yaml
```

---
