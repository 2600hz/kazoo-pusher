# Engineering notes

## Generic Push Notification Mechanism

### `endpoint_push_req` AMQP Payload

```erlang
{[{<<"Account-ID">>, <<"0a06579df80e38ecb6be4215bdfae6c7">>}
 ,{<<"Endpoint">>, {[{<<"ID">>, <<"04072cb66c12b6c0d8454b890d1816a2">>}
                    ,{<<"Type">>, <<"device">>}
                    ]}}

 ,{<<"Collapse-ID">>, <<"{COLLAPSE_ID}">>}
 ,{<<"Priority">>, <<"normal">>}

 ,{<<"Alert">>, {[{<<"Title">>, <<"title">>}
                 ,{<<"Subtitle">>, <<"subtitle">>}
                 ,{<<"Body">>, <<"body">>}
                 ,{<<"Title-Key">>, <<"TITLE">>}
                 ,{<<"Title-Params">>, [<<"Bob">>, <<"Jim">>]}
                 ,{<<"Body-Key">>, <<"BODY">>}
                 ,{<<"Body-Params">>, [<<"Bob">>, <<"Jim">>]}
                 ]}}

 ,{<<"Badge">>, 9}
 ,{<<"Sound">>, <<"bingbong.aiff">>}

 ,{<<"Category">>, <<"{UNNotificationCategory}">>}
 ,{<<"Content-Available">>, 'true'}
 ,{<<"Content-Mutable">>, 'true'}

 %% FCM: `time_to_live`
 %% APNs: computes `apns-expiration` header
 ,{<<"TTL">>, 604800}

 %% APNs only
 ,{<<"APNs">>, {[{<<"Alert">>, {[{<<"Subtitle-Key">>, <<"SUBTITLE">>}
                                ,{<<"Subtitle-Params">>, [<<"Bob">>, <<"Jim">>]}
                                ]}}
                ,{<<"Thread-ID">>, <<"{THREAD_ID}">>}
                ,{<<"Topic">>, <<"com.example.app.voip">>}
                ,{<<"Push-Type">>, <<"voip">>}
                ]}}

 %% FCM Android only
 ,{<<"FCM">>, {[{<<"Android">>, {[{<<"Channel-ID">>, <<"{CHANNEL_ID}">>}
                                 ,{<<"Icon">>, <<"icon.png">>}
                                 ,{<<"Tag">>, <<"{TAG}">>}
                                 ,{<<"Color">>, <<"#000000">>}
                                 ]}}
               ]}}

 %% Custom data
 ,{<<"Data">>, {[{<<"customkey1">>, <<"customvalue1">>}]}}
 ]}
```

#### Schema

Key                          | Type                              | Default  | Required | APNs mapping                  | FCM mapping                       | Description
---------------------------- | --------------------------------- | -------- | -------- | ----------------------------- | --------------------------------- | -----------
`Account-ID`                 | `string(32)`                      |          | `true`   |                               |                                   | The account of the endpoint that should receive the push notification.
`Endpoint.ID`                | `string(32)`                      |          | `true`   |                               |                                   | The endpoint that should receive the push notification.
`Endpoint.Type`              | `"device"` \| `"user"`            |          | `true`   |                               |                                   | The type of endpoint that should receive the push notification. If `"user"`, all that user's devices will receive the same push notification.
`Collapse-ID`                | `string`                          |          | `false`  | header: `apns-collapse-id`    | `collapse_key`                    | Coalesce multiple notifications matching the same ID into one.
`Priority`                   | `"low"` \| `"normal"` \| `"high"` | `"high"` | `false`  | header: `apns-priority`       | `priority`                        | The priority of the notification.
`Alert.Title`                | `string`                          |          | `false`  | `aps.alert.title`             | `notification.title`              | The title of the notification.
`Alert.Subtitle`             | `string`                          |          | `false`  | `aps.alert.subtitle`          | `notification.subtitle`           | The subtitle of the notification.
`Alert.Body`                 | `string`                          |          | `false`  | `aps.alert.body`              | `notification.body`               | The body of the notification.
`Alert.Title-Key`            | `string`                          |          | `false`  | `aps.alert.title-loc-key`     | `notification.title_loc_key`      | The key for a localized notification title.
`Alert.Title-Params`         | `string[]`                        |          | `false`  | `aps.alert.title-loc-args`    | `notification.title_loc_args`     | The array of values to replace placeholders in the localized title.
`Alert.Body-Key`             | `string`                          |          | `false`  | `aps.alert.loc-key`           | `notification.body_loc_key`       | The key for a localized notification body.
`Alert.Body-Params`          | `string[]`                        |          | `false`  | `aps.alert.loc-args`          | `notification.body_loc_args`      | The array of values to replace placeholders in the localized body.
`Badge`                      | `integer`                         |          | `false`  | `aps.badge`                   | `notification.badge`              | The value to set the home screen app icon badge to. `0` removes the badge.
`Sound`                      | `string`                          |          | `false`  | `aps.sound`                   | `notification.sound`              | The name of a sound file to play when the device receives the notification.
`Category`                   | `string`                          |          | `false`  | `aps.category`                | `notification.click_action`       | The app-specific type of notification, which corresponds to a pre-registered `UNNotificationCategory` on iOS or an intent filter launched on click on Android.
`Content-Available`          | `boolean`                         |          | `false`  | `aps.content-available`       | `content_available`               | Specify `true` to deliver the notification as a silent background update on iOS.
`Content-Mutable`            | `boolean`                         |          | `false`  | `aps.mutable-content`         | `mutable_content`                 | Specify `true` to allow a notification service app extension on iOS to modify the notification's content before delivery.
`TTL`                        | `integer`                         |          | `false`  | header: `apns-expiration`     | `time_to_live`                    | The duration (in seconds) for which notification delivery should be retried if it fails.
`APNs.Alert.Subtitle-Key`    | `string`                          |          | `false`  | `aps.alert.subtitle-loc-key`  |                                   | The key for a localized notification subtitle.
`APNs.Alert.Subtitle-Params` | `string[]`                        |          | `false`  | `aps.alert.subtitle-loc-args` |                                   | The array of values to replace placeholders in the localized subtitle.
`APNs.Thread-ID`             | `string`                          |          | `false`  | `aps.thread-id`               |                                   | The app-specific identifier for grouping related notifications.
`APNs.Topic`                 | `string`                          |          | `false`  | header: `apns-topic`          |                                   | The topic for the notification.
`APNs.Push-Type`             | `"alert"` \| `"background"` \| `"complication"` \| `"fileprovider"` \| `"location"` \| `"mdm"` \| `"voip"` | | `false` | header: `apns-push-type` | | The type of push notification.
`FCM.Android.Channel-ID`     | `string`                          |          | `false`  |                               | `notification.android_channel_id` | The pre-registered notification channel to associate the notification with.
`FCM.Android.Icon`           | `string`                          |          | `false`  |                               | `notification.icon`               | The name of a drawable resource to use as the notification's icon.
`FCM.Android.Tag`            | `string`                          |          | `false`  |                               | `notification.tag`                | Replace existing notifications in the notification drawer that have the same tag.
`FCM.Android.Color`          | `string`                          |          | `false`  |                               | `notification.color`              | The color, expressed in `#rrggbb` format, of the notification.
`Data`                       | `object`                          |          | `false`  | <root>                        | `data`                            | The custom data to include in the notification.

### Apple Push Notification service

- <https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/generating_a_remote_notification>
- <https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/sending_notification_requests_to_apns>
- <https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/handling_notification_responses_from_apns>
- payload limit: 5120 bytes for VoIP notifications, 4096 bytes for all other remote notifications

```
apns-id: 8e888176-6f24-457b-9520-f52e12e4b90f
apns-collapse-id: {COLLAPSE_ID}
apns-priority: 5
apns-expiration: 1669330242
apns-topic: com.example.app.voip
apns-push-type: voip
```

```json
{
  "aps": {
    "alert": {
      "title": "title",
      "subtitle": "subtitle",
      "body": "body",
      "title-loc-key": "TITLE",
      "title-loc-args": ["Bob", "Jim"],
      "subtitle-loc-key": "SUBTITLE",
      "subtitle-loc-args": ["Bob", "Jim"],
      "loc-key": "BODY",
      "loc-args": ["Bob", "Jim"]
    },
    "badge": 9,
    "sound": "bingbong.aiff",
    "thread-id": "{THREAD_ID}",
    "category": "{UNNotificationCategory}",
    "content-available": 1,
    "mutable-content": 1
  },
  "customkey1": "customvalue1"
}
```

#### Payload key reference

##### `aps` object

Key                 | Type
------------------- | ----------
`alert`             | `object`
`badge`             | `integer`
`sound`             | `string`
`thread-id`         | `string`
`category`          | `string`
`content-available` | `0` \| `1`
`mutable-content`   | `0` \| `1`

- only supporting `object` for `alert` value (since it covers all the use cases of the `string` version)
- critical alerts (`object` type for `sound` value) are not supported

##### `alert` object

Key                 | Type
------------------- | ----------
`title`             | `string`
`subtitle`          | `string`
`body`              | `string`
`title-loc-key`     | `string`
`title-loc-args`    | `string[]`
`subtitle-loc-key`  | `string`
`subtitle-loc-args` | `string[]`
`loc-key`           | `string`
`loc-args`          | `string[]`

### FCM Legacy HTTP Server Protocol

- <https://firebase.google.com/docs/cloud-messaging/concept-options>
- collapsible messages: <https://firebase.google.com/docs/cloud-messaging/concept-options#which_should_i_use>
  - support for `apns-collapse-id`: <https://github.com/firebase/quickstart-ios/issues/68>
  > Notification messages are always collapsible and will ignore the `collapse_key` parameter.
- we are using [FCM Legacy HTTP Server Protocol](https://firebase.google.com/docs/cloud-messaging/http-server-ref)
  - out of scope in [KPUS-4](https://2600hz-commercial.atlassian.net/browse/KPUS-4) to upgrade to [HTTP v1 Protocol](https://firebase.google.com/docs/reference/fcm/rest/v1/projects.messages#Notification)
    - <https://firebase.google.com/docs/cloud-messaging/migrate-v1>
  - we only support [JSON downstream message syntax](https://firebase.google.com/docs/cloud-messaging/http-server-ref#downstream-http-messages-json) - [plain text](https://firebase.google.com/docs/cloud-messaging/http-server-ref#downstream-http-messages-plain-text) is not supported
- legacy `push_req`s sent all FCM notification information under the `data` object, meaning battery-optimized (device power state aware) `notification` payloads could not be sent
- payload limit: 4096 bytes for most messages, 2048 bytes for messages to topics

```json
{
  "to": "<token>",
  "collapse_key": "{COLLAPSE_ID}",
  "priority": "normal",
  "notification": {
    "title": "title",
    "subtitle": "subtitle",
    "body": "body",
    "title_loc_key": "TITLE",
    "title_loc_args": ["Bob", "Jim"],
    "body_loc_key": "BODY",
    "body_loc_args": ["Bob", "Jim"],
    "badge": "9",
    "sound": "sound.wav",
    "click_action": "{INTENT_FILTER}"
  },
  "content_available": true,
  "mutable_content": true,
  "time_to_live": 604800,
  "data": {
    "customkey1": "customvalue1"
  }
}
```

#### Downstream message syntax

Key                 | Type
------------------- | ----------------------
`to`                | `string`
`collapse_key`      | `string`
`priority`          | `"normal"` \| `"high"`
`content_available` | `boolean`
`mutable_content`   | `boolean`
`time_to_live`      | `integer`
`data`              | `object`
`notification`      | `object`

#### Notification payload support

Key                  | Type
-------------------  | ----------
`title`              | `string`
`subtitle`           | `string`
`body`               | `string`
`title_loc_key`      | `string`
`title_loc_args`     | `string[]`
`body_loc_key`       | `string`
`body_loc_args`      | `string[]`
`badge`              | `string`
`sound`              | `string`
`click_action`       | `string`
`android_channel_id` | `string`
`icon`               | `string`
`tag`                | `string`
`color`              | `string`
