##
#Need to have Az CLI installed

##

############
# Set Variables
##############
$AZ_SUBSCRIPTION="" #Your subscription id
$AZ_RESOURCE_GROUP="" #Your resource group
$AZ_LOCATION="" #What location you want your resources created in
$AZ_StorageAccountName="" #Storage Account to create
$AZ_EndpointName="" #CDN Endpoint Name
$AZ_ProfileName="" #CDN Profile Name
$AZ_HostName="" #Custom Domain Name
$AZ_DomainName="" #Domain Name
$AZ_KeyVault_Name="" #Keyvault Name
$AZ_IPAdrressAllow="" #Your IP Address to access the Keyvault
$AZ_CertName="" #Name of your cert


#Lgin to Azure - for the subscription you are using make sure you have owner rights
#az login
#az account set -s $AZ_SUBSCRIPTION

#Create Resource Group
az group create --resource-group $AZ_RESOURCE_GROUP --location $AZ_LOCATION

#Create the storage account 
az storage account create -n $AZ_StorageAccountName -g $AZ_RESOURCE_GROUP --sku Standard_LRS --min-tls-version TLS1_2

#Enable static website hosting
az storage blob service-properties update --account-name $AZ_StorageAccountName --static-website --404-document 404.html --index-document index.html

#Upload the contents of this directory to the web container
az storage blob upload-batch -s .\web -d '$web' --account-name $AZ_StorageAccountName --content-type 'text/html; charset=utf-8'


#Map a custom domain with HTTPS enabled

# Create the CDN profile
az cdn profile create --name $AZ_ProfileName -g $AZ_RESOURCE_GROUP -l $AZ_LOCATION --sku Standard_Microsoft


#Get the primary web url for use later
$AZ_PrimaryWebOrigin=$(az storage account show -n $AZ_StorageAccountName -g $AZ_RESOURCE_GROUP --query "primaryEndpoints.web" --output tsv)

#Remove the staring https and trailing /
$OriginHostheader=$AZ_PrimaryWebOrigin.Substring(8,($AZ_PrimaryWebOrigin.Length - 9))


#Now need to create a CNAME with your DNS provider to reference this endpoint. I use Cloudflare - this will take some time to propogate. I had to add 2 cnames for this to work
#Type = CNAME 
#name = yourdomainname
#content = yourdomainname.azureedge.net
#Type = CNAME 
#name = cdnverify
#content = cdnverify.yourdomainname.azureedge.net


#Add the endpoint to the CDN 
az cdn endpoint create --name $AZ_EndpointName -g $AZ_RESOURCE_GROUP --profile-name $AZ_ProfileName --origin $OriginHostheader 80 443 --origin-host-header $OriginHostheader

#Create Keyvault - check what network access is granted with this
az keyvault create -l $AZ_LOCATION -g $AZ_RESOURCE_GROUP -n $AZ_KeyVault_Name --sku Standard --default-action Deny

#Grant access to your IP Address
az keyvault network-rule add -n $AZ_KeyVault_Name -g $AZ_RESOURCE_GROUP --ip-address $AZ_IPAdrressAllow

#HTTPS Certificate and Keyvault

#I use WSL2 on my windows machine so I installed certbot there and use the manual mode to request a certficate from Lets Encrypt.
#Then convert that to PFX format and upload it to keyvault. 

#Install certbot and run the following command. The cert needs to be in RSA format in order to work with the Azure CDN
#sudo certbot certonly --cert-name yourdomainname --manual -d yourdomainname --key-type rsa --preferred-challenges dns

#It will ask you to create a txt entry in your dns provider with a specific content value. Do that and then continue

#Once the cert is created run the following command to concvert to PFX format - change paths and domains to match yours
#sudo openssl pkcs12 -export -inkey /etc/letsencrypt/live/yourdomainname/privkey.pem -in /etc/letsencrypt/live/yourdomainname/fullchain.pem -name insideleft.co.uk -out yourdomainname.pfx

#Now import that certificate into your keyvault
az keyvault certificate import --file .\certs\insideleftcouk.pfx -n $AZ_CertName --vault-name $AZ_KeyVault_Name
                             
#Map Azure CDN to your domain.
az cdn custom-domain create -g $AZ_RESOURCE_GROUP --endpoint-name $AZ_EndpointName --profile-name $AZ_ProfileName -n $AZ_DomainName  --hostname $AZ_HostName

#In order to enable HTTPS on your custom domain you need to Register Azure CDN as an app in your Azure Active Directory.
#https://learn.microsoft.com/en-us/azure/cdn/cdn-custom-ssl?tabs=option-2-enable-https-with-your-own-certificate
#205478c0-bd83-4e1b-a9d6-db63a3e1e1c8 is the service principal for Microsoft.AzureFrontDoor-Cdn.
az ad sp create --id 205478c0-bd83-4e1b-a9d6-db63a3e1e1c8

#Then need to get the object id of Microsoft.AzureFrontDoor-Cdn = 3a4b744e-41e7-4d4b-9084-cd40129ba9ee

#Create an access policy to allow the Azure CDN access your key vault
az keyvault set-policy --name $AZ_KeyVault_Name -g $AZ_RESOURCE_GROUP `
    --object-id 3a4b744e-41e7-4d4b-9084-cd40129ba9ee `
    --certificate-permissions get  `
    --secret-permissions get 


#Then enable https with keyvault - check the fu required for name!
$AZ_HostName = $AZ_HostName -replace '\.','-'
az cdn custom-domain enable-https -g $AZ_RESOURCE_GROUP `
--endpoint-name $AZ_EndpointName `
--profile-name $AZ_ProfileName `
--name $AZ_HostName `
--user-cert-group-name $AZ_RESOURCE_GROUP `
--user-cert-secret-name $AZ_CertName `
--user-cert-vault-name $AZ_KeyVault_Name `
--user-cert-protocol-type sni `
                          