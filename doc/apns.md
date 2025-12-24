
# Pusher - APNS

Kazoo Pusher supports both certificate based and token based authentication for Apple Push Notification Service (APNs). It also includes enhanced push handling logic to meet Apple’s guidelines for VoIP and alert notifications.

This document provides a comprehensive overview of all configuration options related to APNs authentication and push notification behavior in Pusher.

## Authentication Configuration

APNs authentication is controlled using the `auth_type` field in System Config.

* `certdata` - Certificate based authentication
* `token` - Token based authentication

### Certificate Based Authentication

When using certificate based authentication (`auth_type` = `certdata`), the `certificate` field must be configured with the PEM encoded key and certificate.

### Token Based Authentication

When token-based authentication is enabled (`auth_type` = `token`), Kazoo Pusher authenticates with Apple Push Notification service (APNs) using an Apple-issued APNs Auth Key (.p8).

The following configuration parameters are required.

* `team_id` - The Apple Developer Team ID associated with your Apple Developer account (10 characters).
* `key_id` - The Key ID of the APNs Auth Key (.p8) generated in the Apple Developer Portal.

In addition, the PEM-encoded APNs private key (.p8) must be configured using the following command.

`sup pusher_maintenance add_apple_pem_file PemKeyFile`

As an example, `sup pusher_maintenance add_apple_pem_file /path/to/AuthKey_ABC123XYZ.p8`

#### Token Refresh

Tokens must be refreshed periodically. `token_refresh_window` specifies the interval in minutes.
  * Minimum allowed value - 20 minutes
  * Maximum allowed value - 60 minutes
  * Default value - 55 minutes

### Switching Between Authentication Methods

If you change between certificate based and token based authentication, it is required to restart the Pusher application after updating the configuration.

## Custom APNs Push Type Handling

When `enable_custom_apns_push_type` is set to `true`, Kazoo Pusher dynamically selects the correct APNs push type (`apns_push_type`) and adjusts the APNs topic (`apns_topic`) based on the event type, ensuring compliance with Apple’s APNs push delivery guidelines.

### Push Type Mapping

* For `incoming_call` events - APNs push type becomes `voip`
* For `voicemail` events - APNs push type becomes `alert`
* For `missed_call` events - APNs push type becomes `alert`
* For all other events - The default configured push type is used

### APNs Topic Adjustment

Apple requires the APNs topic to differ between VoIP and alert notifications.

Based on `apns_push_type`:
* When using voip pushes - A `.voip` suffix is added to the APNs topic
* When using alert pushes - Any `.voip` suffix is removed from the APNs topic

#### Example Behavior

* If `apns_push_type` = `voip` : `apns_topic` = com.example.app.voip
* If `apns_push_type` = `alert` : `apns_topic` = com.example.app
