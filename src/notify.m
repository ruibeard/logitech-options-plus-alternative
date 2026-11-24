#import <UserNotifications/UserNotifications.h>
#include "notify.h"

void mx_notify(const char *title, const char *body) {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = @(title); content.body = @(body);
    content.sound = UNNotificationSound.defaultSound;
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"local.mxmouse.battery" content:content trigger:nil];
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
        completionHandler:^(BOOL granted, NSError *error) {
            (void)error;
            if (granted) [center addNotificationRequest:request withCompletionHandler:nil];
        }];
}
