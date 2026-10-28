make dev-up
make dev-deploy

kubectl get openchamicontrolplane testcluster -w 
kubectl get pods -n openchami-testcluster