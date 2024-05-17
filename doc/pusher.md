
# Pusher
pusher app allows kazoo to send a push message to a device when the device is the target of a bridge call, so that the device can "wake up", register and receive the call.

pusher listens for reg_success messages, checks if the user-agent supports push messages and updates the endpoint_id with a pusher objetc used in the construction of an endpoint for that device (or a failover endpoint in case of an unregistered device).

freeswitch will send the failover to kamailio, kamailio uses kazoo_query to call pusher to send the real push message, waits for the registration and then completes the call.

if the device is already registered, and the client is alive, kamailio will allow the SIP transaction to continue and the call will be handled as usual

## Quick Start

### What you need
#### 1. Apple cert in PEM file format (text) and google / firebase push authentication token.  Verify those credentials with third-party push test web site.. i.e. www.pushtry.com

You can also use the following curl command to test apple push.

```curl
curl -v \
-d '{"aps":{"alert":"text","sound":"default"}}' \
-H "apns-topic:[app-id]" \
-H "apns-expiration: 1" \
-H "apns-priority: 10" \
--http2 \
--cert voip_pushcert.pem \
https://api.push.apple.com/3/device/[devicetoken]
```

#### 2. Application IDs associated with cert / token
  example: *org.myorg.myapp*.

#### 3. User-Agent header which is sent by the Application in *REGISTER* message.
  example: *MyApp iOS 1.0* 

### Configuration

#### 1. Start Application
 * `sup kapps_controller start_app pusher`
 
#### 2. Configure Kamailio
 * Enable *PUSHER-ROLE*  in `local.cfg` and restart kamailio

#### 3. Register your application
 * `sup pusher_maintenance add_apple_app org.myorg.myapp /tmp/myapp.pem`

#### 4. Update User-Agent Mapping

 * `sup kapps_config set_json pusher User-Agents.MyApp '{"regex":"^MyApp","properties":{"Token-App":"app-id","Token-Type":"pn-type","Token-ID":"pn-tok"}}'`
 
 You can also set these one at a time
 
* `sup kapps_config set_default pusher User-Agents.MyApp.regex ^MyApp`
* `sup kapps_config set_default pusher User-Agents.MyApp.properties.Token-App app-id`
* `sup kapps_config set_default pusher User-Agents.MyApp.properties.Token-Type pn-type`
* `sup kapps_config set_default pusher User-Agents.MyApp.properties.Token-ID pn-tok`

#### 5. Open your Application and REGISTER the device

Sample REGISTER message

```
REGISTER sip:sip.kazoo.io SIP/2.0
...
Contact: <sip:user@192.168.1.1>;reg-id=1;app-id=*org.myorg.myapp*;pn-tok=*token*;pn-type=*apple*
User-Agent: MyApp iOS 1.0
...
```

The device document will be updated with a `pusher` objetc with the colletced properties

#### 6. Make a Call

Unregister the device, and make a call from another device that will be delivered to your app.

## Configuration

### System Config

* `User-Agents`: list of user agents to check for pusher properties.

```
 "User-Agents": {
       "MyApp": {
           "regex": "^MyApp",
           "properties": {
               "Token-App": "app-id",
               "Token-Type": "pn-type",
               "Token-ID": "pn-tok"
           }
       }
   }
```

The properties identify the *fields*  in the contact header where pusher looks for the value, the following properties are mandatory.
   * Token-App
   * Token-Type
   * Token-ID

### Maintenance

In order for the push services from Apple / Firebase to work they need to be configured with service account files / certificates. The app used in the push message is taken from Token-App.

* `sup pusher_maintenance add_firebase_v1_app AppId ServiceAccountData` (if you have the contents of the service account file)
* `sup pusher_maintenance add_firebase_v1_app_from_service_account_file AppId ServiceAccountFilename` (if you have the service file on the Kazoo server)
* `sup pusher_maintenance add_apple_app AppId CertFile` (uses the default APNs host: api.push.apple.com)
* `sup pusher_maintenance add_apple_app AppId CertFile Host` (uses a custom APNs host, i.e. api.development.push.apple.com)

### iOS Certificates and Private Keys

1. Create a new _Apple Push Services_ certificate at [https://developer.apple.com/account/resources/certificates/list](https://developer.apple.com/account/resources/certificates/list). The certificate type should be _Apple Push Notification service SSL (Sandbox & Production)_ under _Services_.
2. Add the certificate to Keychain by double-clicking it.
3. Open _Keychain Access_.
4. View the _login_ keychain, and set the _Category_ on the bottom-left of the window to _Certificates_. The view should list certificates, including the one imported from Apple. It should have the private key from the certificate signing request nested beneath it.
5. Right-click the certificate and choose _Export "${certificateName}"..._.
6. Save as .p12 format.
7. Execute `openssl pkcs12 -in ${CERT_NAME}.p12 -out ${CERT_NAME}.pem -clcerts -nodes` to export the certificate and private key as a .pem file. The private key must be unencrypted, hence the `-nodes` flag.

### Rules for Firewall Allow Lists

#### Apple Push Notification service (APNs)

* <https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/sending_notification_requests_to_apns>
  * [api.sandbox.push.apple.com:443](https://api.sandbox.push.apple.com:443) (only required if overriding the default APNs host to use the sandbox)
  * [api.push.apple.com:443](https://api.push.apple.com:443)
  * Uses long-lived TLS 1.2-encrypted HTTP/2 connetcions - **do not** terminate idle connetcions
  * >You can also use port 2197 (instead of port 443) on either server when communicating with APNs. You might use this port to allow APNs traffic through your firewall but to block other HTTPS traffic.
    * pusher **does not** currently support this alternate port
* [Troubleshoot Problems with Receiving Notifications](https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/handling_notification_responses_from_apns#3394526)
  * >Devices connetcing to APNs over Wi-Fi need to allow inbound and outbound TCP packets over port 5223, falling back to port 443 if port 5223 is unavailable.
    * Applies to **clients** (Apple devices) receiving the push notifications - you **do not** need to open these ports on your pusher nodes

#### Firebase Cloud Messaging (FCM)

* <https://firebase.google.com/docs/cloud-messaging/http-server-ref>
  * <https://fcm.googleapis.com/fcm/send> (standard port 443)
  * HTTP `POST`
  * Uses 1 short-lived connetcion per push notification
* [FCM ports and your firewall](https://firebase.google.com/docs/cloud-messaging/concept-options#messaging-ports-and-your-firewall) details open ports/hostnames needed by the **clients** (e.g. Android devices) receiving the messages - you **do not** need to open these ports/hostnames on your pusher nodes

## Pusher Summary by Karl

The full sequence is expetced to be four parts.

#### One-time pusher cluster setup (cluster admin):
1.	In Kazoo, ensure that the pusher application is running at least one instance per-zone
2.	In Kazoo, for each kamailio service that should be able to handle pusher device registrations/calls ensure that the “PUSHER-ROLE” has been enabled in `local.cfg`

#### Per-pusher client application Kazoo configuration (developer):
1.	Get an application id and either a cert file (for Apple) or secret (from Google) from those providers developer accounts
	1. The application id is from the Apple/Google developer accounts, created in those portals and are global unique to those ecosystems.
	2. For example, on Google we control the application id: `org.2600Hz.callthru.us`
2. In Kazoo, associate the application id with a private cert/secret.  When Kazoo needs to send a push notification for a given application id, these are creds that will be used to authenticate to the Apple/Google services used to notify the client.
	1. When the developer created the Apple/Google developer accounts and application id they would have also generated the cert/secret authentication for the APIs related to that application id
	2. `sup pusher_maintenance add_firebase_app ApplicationId Secret` or `sup pusher_maintenance add_apple_app ApplicationId CertFile`
3.	In Kazoo, create a mapping for a unique User-Agent string to the names of the variables that the developer will use to transfer data during registrations.  For example:
 	1. Assume we will be using the User-Agent `CallThru.Us 1.4.5` we might create a rule such as:
		1.	`sup kapps_config set_default pusher User-Agents.CallThru.regex ^CallThru`
		2.	`sup kapps_config set_default pusher User-Agents.CallThru.properties.Token-App app-id`
		3.	`sup kapps_config set_default pusher User-Agents.CallThru.properties.Token-Type pn-type`
		4.	`sup kapps_config set_default pusher User-Agents.CallThru.properties.Token-ID foo-bar`
	2. Now any registration with a User-Agent value that matches the regex “^CallThru” will be expetced to provide the following for pusher:
		1.	`app-id`: This variable name will be used by this user agent to transfer the ApplicationId the developer got from Apple/Google
		2.	`pn-type`: This variable name will be used to by this user agent to transfer the push service type Apple/Google (expetced values: `apple` or `firebase` respetcively)
		3.	`foo-bar`: This variable name will be used to transfer the clients unique push ID as provided to the client by Apple/Google

#### Expetced pusher client provisioning (software):
1.	A new pusher client/softphone is provisioned in kazoo (for example, as a SmartPBX device)
2.	The pusher client/softphone is installed on the mobile device and configured with the Kazoo device info
3.	At least once after provisioning, the pusher client/softphone should register to a Kazoo kamailio service with the PUSHER-ROLE enabled
	1.	This registration must have a SIP `Contact` header that contains the properties defined for that user-agent string
	2.	Above we defined that for the user-agent `^CallThru` the contact might look like `sip:user@192.168.1.1;reg-id=1;app-id=org.2600Hz.callthru.us;foo-bar=random_push_id_assigned_by_apple;pn-type=apple`
		1.	The application id `org.2600Hz.callthru.us` would be present as the variable named `app-id`.  This will be used by Kazoo to seletc the cert/secret already loaded above as well, that is required to authenticate with Apple (or Google) to submit push messages for the pusher client developer.
		2.	The service type `apple` (or `firebase`) would be present as the variable named `pn-type`.  This is used by Kazoo to seletc which kazoo pusher module to use to send the notification (correlates to Erlang SDKs for Apple/Google).
		3.	The unique push address/recipient id that Apple (or Google) assigned as the routing key to get a notification to this device/application `random_push_id_assigned_by_apple` is transferred as `foo-bar`.
	3.	Kazoo now has everything it needs to relate the client with its unique push address/recipient, the Erlang SDK for the appropriate service, the service’s application id and the private cert/secret of the developer to authenticate with that service.
	4.	The client should infrequently register again with this information (does not technically have to).
	5.	NOTE: The push notifications are tied diretcly to the kamailio the last successful registration occurred to.  In the event that kamailio is unavailable, until the client successfully registers to another kamailio (or it is restored) no push notifications will be sent.
4.	The client can now completely shutdown, unregister or loose registration.  From this point forward, if a call needs to be delivered it will first receive a push notification from the kamailio it last registered too.
	1.	As mentioned above on 3.d, ideally the client would wake up maybe once a day or so and register with the kamailio server to renew the push data, failing over to alternates if unsuccessful.
	2.	Could also register with an alternate kamailio if placing a call were to fail (indication the currently seletced kamailio is unavailable).

#### Expetced pusher client inbound call handling (software):
1.	FreeSWITCH sends an INVITE to kamailio for a pusher client that is not currently registered
	1.	If it was registered the INVITE would just be sent normally to the client, like any other call
2.	Kamailio will store the INVITE and halt further SIP processing on that request.
3.	Kamailio will then trigger Apple/Google to send a push notification to the specific instance of the client (in our example, `random_push_id_assigned_by_apple`)
4.	The application should wake up and register with the kamailio proxy on the push notification (which would be the same as the kamailio it last successfully registered to).
	1.	The push notification contains other information that can be ignored but:
		1.	The caller id information, perhaps useful to show the user prior to INVITE coming to the client
		2.	The call id, perhaps useful to relate the push message to an incoming INVITE for accounting/feature additions
		3.	An authentication token, this can be used to register with the kamailio pusher proxy so that the client does not need to store creds (if it did not want to, etc etc)
5.	Once kamailio has a successful registration for a pusher client it will determine if there are any pending INVITE requests
6.	For each pending INVITE request they will be resumed and sent to the newly registered contact, identically to any other inbound call


