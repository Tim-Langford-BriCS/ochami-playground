#!/bin/bash
# §11 progress probe — read-only, safe to re-run.
hr(){ printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
ok(){ printf '  \033[32m PASS \033[0m %s\n' "$1"; }
no(){ printf '  \033[31m FAIL \033[0m %s\n' "$1"; }
huh(){ printf '  \033[33m ???? \033[0m %s\n' "$1"; }

hr "11.1  cluster reachable"
if timeout 20 kubectl get --raw=/readyz >/dev/null 2>&1; then
  ok "API server ready"
  kubectl get nodes -o wide --no-headers | sed 's/^/    /'
else
  no "API server not answering — stop here, nothing below is meaningful"
  exit 1
fi

hr "11.2  storage"
if kubectl get sc local-path --no-headers >/dev/null 2>&1; then
  ok "storageclass local-path present"
else
  no "storageclass local-path absent — start at the apply in 11.2"
fi
kubectl get sc 2>/dev/null | sed 's/^/    /'
kubectl -n local-path-storage get deploy,pods --no-headers 2>/dev/null | sed 's/^/    /'

p=$(kubectl -n local-path-storage get cm local-path-config -o jsonpath='{.data.config\.json}' 2>/dev/null)
case "$p" in
  *"/var/local-path-provisioner"*) ok "configmap on /var/local-path-provisioner — the Talos patch applied" ;;
  *"/var/mnt"*) no "configmap on /var/mnt — read-only to the kubelet, PVCs will never bind (issue 007)" ;;
  *"/opt"*)     no "configmap still on /opt — apply the 11.2 configmap patch + rollout restart" ;;
  *)            huh "local-path-config not found" ;;
esac

echo "  kubelet extraMounts (needs one entry per node, or the helper pod cannot mkdir):"
for n in 172.16.0.1 172.16.0.2 172.16.0.3; do
  m=$(talosctl -n "$n" get machineconfig -o yaml 2>/dev/null | grep -c 'local-path-provisioner')
  [ "${m:-0}" -gt 0 ] && ok "$n has the extraMounts entry" || no "$n missing extraMounts — issue 007"
done

if kubectl get sc local-path -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null | grep -q true; then
  ok "local-path is the default class"
else
  no "local-path is not default — run the patch storageclass step"
fi

echo "  smoke-test leftovers (expect NotFound once 11.2 is finished and cleaned up):"
kubectl get pvc smoke --no-headers 2>&1 | sed 's/^/    /'
kubectl get pod smoke --no-headers 2>&1 | sed 's/^/    /'

hr "11.3  metrics-server"
if kubectl -n kube-system get deploy metrics-server >/dev/null 2>&1; then
  kubectl -n kube-system get deploy metrics-server --no-headers | sed 's/^/    /'
  kubectl -n kube-system get deploy metrics-server \
    -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | tr ',' '\n' | sed 's/^/    arg: /'
  echo
  if kubectl -n kube-system get deploy metrics-server \
       -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | grep -q insecure; then
    huh "--kubelet-insecure-tls present — the POC workaround, issue 008. Owed a proper fix after §15"
  fi
  timeout 30 kubectl top nodes 2>&1 | sed 's/^/    /'
else
  no "metrics-server not installed — 11.3"
fi

hr "11.4  Gateway API / cert-manager / gateway implementation"
n=$(kubectl get crd 2>/dev/null | grep -c 'gateway.networking.k8s.io')
[ "$n" -gt 0 ] && ok "Gateway API CRDs: $n" || no "Gateway API CRDs absent — 11.4"
n=$(kubectl get crd 2>/dev/null | grep -c 'cert-manager.io')
[ "$n" -gt 0 ] && ok "cert-manager CRDs: $n"  || no "cert-manager CRDs absent — 11.4"
kubectl -n cert-manager        get deploy --no-headers 2>/dev/null | sed 's/^/    /'
kubectl -n envoy-gateway-system get deploy --no-headers 2>/dev/null | sed 's/^/    /'
if kubectl get gatewayclass --no-headers 2>/dev/null | grep -q .; then
  kubectl get gatewayclass 2>&1 | sed 's/^/    /'
  kubectl get gatewayclass -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.conditions[?(@.type=="Accepted")].status}{"\n"}{end}' 2>/dev/null \
    | grep -q '=True' && ok "a GatewayClass is Accepted" || no "GatewayClass exists but is not Accepted — controllerName mismatch"
else
  no "no GatewayClass — the chart installs the controller but not the class, 11.4"
fi
if command -v helm >/dev/null 2>&1; then
  ok "helm installed: $(helm version --short 2>/dev/null)"
else
  no "helm not installed — 11.4"
fi

hr "anything unhealthy, anywhere"
kubectl get pods -A 2>/dev/null | grep -Ev 'Running|Completed' | sed 's/^/    /'
echo
