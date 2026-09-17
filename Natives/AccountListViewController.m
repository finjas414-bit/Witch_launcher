#import <AuthenticationServices/AuthenticationServices.h>

#import "authenticator/BaseAuthenticator.h"
#import "AccountListViewController.h"
#import "AFNetworking.h"
#import "LauncherPreferences.h"
#import "UIImageView+AFNetworking.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

@interface AccountListViewController()<ASWebAuthenticationPresentationContextProviding>

@property(nonatomic, strong) NSMutableArray *accountList;
@property(nonatomic) ASWebAuthenticationSession *authVC;

@end

@implementation AccountListViewController

- (BOOL)isValidAccountDictionary:(id)object {
    if (![object isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    NSDictionary *account = (NSDictionary *)object;
    id username = account[@"username"];
    return [username isKindOfClass:[NSString class]] && ((NSString *)username).length > 0;
}

- (NSDictionary *)safeAccountAtIndex:(NSInteger)index {
    if (index < 0 || index >= self.accountList.count) {
        return nil;
    }
    id account = self.accountList[index];
    if (![self isValidAccountDictionary:account]) {
        return nil;
    }
    return (NSDictionary *)account;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    if (self.accountList == nil) {
        self.accountList = [NSMutableArray array];
    } else {
        [self.accountList removeAllObjects];
    }

    // List accounts
    const char *home = getenv("POJAV_HOME");
    if (home == NULL || home[0] == '\0') {
        NSLog(@"[Accounts] POJAV_HOME is missing; skipping account list load");
        [self.tableView setSeparatorStyle:UITableViewCellSeparatorStyleSingleLine];
        return;
    }

    NSString *listPath = [NSString stringWithFormat:@"%s/accounts", home];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:listPath error:nil];
    if (files == nil) {
        [self.tableView setSeparatorStyle:UITableViewCellSeparatorStyleSingleLine];
        return;
    }

    for (NSString *file in files) {
        NSString *path = [listPath stringByAppendingPathComponent:file];
        BOOL isDir = NO;
        [fm fileExistsAtPath:path isDirectory:(&isDir)];
        if (!isDir && [file hasSuffix:@".json"]) {
            NSDictionary *account = parseJSONFromFile(path);
            if ([self isValidAccountDictionary:account]) {
                [self.accountList addObject:account];
            } else {
                NSLog(@"[Accounts] Ignoring invalid account file: %@", path);
            }
        }
    }

    [self.tableView setSeparatorStyle:UITableViewCellSeparatorStyleSingleLine];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.accountList.count + 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];

    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
    }

    if (indexPath.row == self.accountList.count) {
        cell.imageView.image = [UIImage imageNamed:@"IconAdd"];
        cell.textLabel.text = localize(@"login.option.add", nil);
        return cell;
    }

    NSDictionary *selected = [self safeAccountAtIndex:indexPath.row];
    if (selected == nil) {
        cell.textLabel.text = localize(@"login.option.add", nil);
        cell.detailTextLabel.text = nil;
        cell.imageView.image = nil;
        return cell;
    }

    NSString *username = selected[@"username"];
    cell.textLabel.text = username;
    if ([username hasPrefix:@"Demo."]) {
        cell.textLabel.text = [username substringFromIndex:5];
        cell.detailTextLabel.text = localize(@"login.option.demo", nil);
    } else if (selected[@"xboxGamertag"] == nil) {
        cell.detailTextLabel.text = localize(@"login.option.local", nil);
    } else {
        cell.detailTextLabel.text = selected[@"xboxGamertag"];
    }

    cell.imageView.contentMode = UIViewContentModeCenter;
    NSString *avatarURL = selected[@"profilePicURL"];
    if ([avatarURL isKindOfClass:[NSString class]] && avatarURL.length > 0) {
        [cell.imageView setImageWithURL:[NSURL URLWithString:[avatarURL stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"]] placeholderImage:[UIImage imageNamed:@"DefaultAcc"]];
    } else {
        cell.imageView.image = [UIImage imageNamed:@"DefaultAcc"];
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];

    if (indexPath.row == self.accountList.count) {
        [self actionAddAccount:cell];
        return;
    }

    NSDictionary *selected = [self safeAccountAtIndex:indexPath.row];
    if (selected == nil) {
        return;
    }

    self.modalInPresentation = YES;
    self.tableView.userInteractionEnabled = NO;
    [self addActivityIndicatorTo:cell];

    id callback = ^(id status, BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^(){
            [self callbackMicrosoftAuth:status success:success forCell:cell];
        });
    };
    NSString *username = selected[@"username"];
    [[BaseAuthenticator loadSavedName:username] refreshTokenWithCallback:callback];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        NSDictionary *selected = [self safeAccountAtIndex:indexPath.row];
        if (selected == nil) {
            return;
        }

        NSString *str = selected[@"username"];
        NSFileManager *fm = [NSFileManager defaultManager];
        const char *home = getenv("POJAV_HOME");
        if (home == NULL || home[0] == '\0') {
            return;
        }

        NSString *path = [NSString stringWithFormat:@"%s/accounts/%@.json", home, str];
        if (self.whenDelete != nil) {
            self.whenDelete(str);
        }
        NSString *xuid = selected[@"xuid"];
        if ([xuid isKindOfClass:[NSString class]] && xuid.length > 0) {
            [MicrosoftAuthenticator clearTokenDataOfProfile:xuid];
        }
        [fm removeItemAtPath:path error:nil];
        [self.accountList removeObjectAtIndex:indexPath.row];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
    }
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.row == self.accountList.count) {
        return UITableViewCellEditingStyleNone;
    } else {
        return UITableViewCellEditingStyleDelete;
    }
}

- (NSDictionary *)parseQueryItems:(NSString *)url {
    NSMutableDictionary *result = [NSMutableDictionary new];
    NSArray<NSURLQueryItem *> *queryItems = [NSURLComponents componentsWithString:url].queryItems;
    for (NSURLQueryItem *item in queryItems) {
        result[item.name] = item.value;
    }
    return result;
}

- (void)actionAddAccount:(UITableViewCell *)sender {
    UIAlertController *picker = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    UIAlertAction *actionMicrosoft = [UIAlertAction actionWithTitle:localize(@"login.option.microsoft", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self actionLoginMicrosoft:sender];
    }];
    [picker addAction:actionMicrosoft];
    UIAlertAction *actionLocal = [UIAlertAction actionWithTitle:localize(@"login.option.local", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self actionLoginLocal:sender];
    }];
    [picker addAction:actionLocal];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil];
    [picker addAction:cancel];

    picker.popoverPresentationController.sourceView = sender;
    picker.popoverPresentationController.sourceRect = sender.bounds;

    [self presentViewController:picker animated:YES completion:nil];
}

- (void)actionLoginLocal:(UIView *)sender {
    if (getPrefBool(@"warnings.local_warn")) {
        setPrefBool(@"warnings.local_warn", NO);
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"login.warn.title.localmode", nil) message:localize(@"login.warn.message.localmode", nil) preferredStyle:UIAlertControllerStyleAlert];
        alert.popoverPresentationController.sourceView = sender;
        alert.popoverPresentationController.sourceRect = sender.bounds;
        UIAlertAction *ok = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {[self actionLoginLocal:sender];}];
        [alert addAction:ok];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    UIAlertController *controller = [UIAlertController alertControllerWithTitle:localize(@"Sign in", nil) message:localize(@"login.option.local", nil) preferredStyle:UIAlertControllerStyleAlert];
    [controller addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = localize(@"login.alert.field.username", nil);
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.borderStyle = UITextBorderStyleRoundedRect;
    }];
    [controller addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSArray *textFields = controller.textFields;
        UITextField *usernameField = textFields[0];
        if (usernameField.text.length < 3 || usernameField.text.length > 16) {
            controller.message = localize(@"login.error.username.outOfRange", nil);
            [self presentViewController:controller animated:YES completion:nil];
        } else {
            id callback = ^(id status, BOOL success) {
                if (self.whenItemSelected != nil) {
                    self.whenItemSelected();
                }
                [self dismissViewControllerAnimated:YES completion:nil];
            };
            [[[LocalAuthenticator alloc] initWithInput:usernameField.text] loginWithCallback:callback];
        }
    }]];
    [controller addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:controller animated:YES completion:nil];
}

- (void)actionLoginMicrosoft:(UITableViewCell *)sender {
    NSURL *url = [NSURL URLWithString:@"https://login.live.com/oauth20_authorize.srf?client_id=00000000402b5328&response_type=code&scope=service%3A%3Auser.auth.xboxlive.com%3A%3AMBI_SSL&redirect_uri=ms-xal-00000000402b5328%3A%2F%2Fauth&response_mode=query&prompt=select_account"];

    self.authVC =
        [[ASWebAuthenticationSession alloc] initWithURL:url
        callbackURLScheme:@"ms-xal-00000000402b5328"
        completionHandler:^(NSURL * _Nullable callbackURL, NSError * _Nullable error)
    {
        if (callbackURL == nil) {
            if (error.code != ASWebAuthenticationSessionErrorCodeCanceledLogin) {
                showDialog(localize(@"Error", nil), error.localizedDescription);
            }
            return;
        }

        NSDictionary *queryItems = [self parseQueryItems:callbackURL.absoluteString];
        if (queryItems[@"code"]) {
            dispatch_async(dispatch_get_main_queue(), ^(){
                self.modalInPresentation = YES;
                self.tableView.userInteractionEnabled = NO;
                [self addActivityIndicatorTo:sender];
            });
            id callback = ^(id status, BOOL success) {
                if ([status isKindOfClass:NSString.class] && [status isEqualToString:@"DEMO"] && success) {
                    showDialog(localize(@"login.warn.title.demomode", nil), localize(@"login.warn.message.demomode", nil));
                }
                dispatch_async(dispatch_get_main_queue(), ^(){
                    [self callbackMicrosoftAuth:status success:success forCell:sender];
                });
            };
            [[[MicrosoftAuthenticator alloc] initWithInput:queryItems[@"code"]] loginWithCallback:callback];
        } else {
            if ([queryItems[@"error"] hasPrefix:@"access_denied"]) {
                return;
            }
            showDialog(localize(@"Error", nil), queryItems[@"error_description"]);
        }
    }];

    self.authVC.prefersEphemeralWebBrowserSession = YES;
    self.authVC.presentationContextProvider = self;

    if ([self.authVC start] == NO) {
        showDialog(localize(@"Error", nil), @"Unable to open Safari");
    }
}

- (void)addActivityIndicatorTo:(UITableViewCell *)cell {
    if (cell == nil) {
        return;
    }
    UIActivityIndicatorViewStyle indicatorStyle = UIActivityIndicatorViewStyleMedium;
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:indicatorStyle];
    cell.accessoryView = indicator;
    [indicator sizeToFit];
    [indicator startAnimating];
}

- (void)removeActivityIndicatorFrom:(UITableViewCell *)cell {
    if (cell == nil) {
        return;
    }
    UIActivityIndicatorView *indicator = (id)cell.accessoryView;
    if ([indicator isKindOfClass:[UIActivityIndicatorView class]]) {
        [indicator stopAnimating];
    }
    cell.accessoryView = nil;
}

- (void)callbackMicrosoftAuth:(id)status success:(BOOL)success forCell:(UITableViewCell *)cell {
    if (status != nil) {
        if (success) {
            if ([cell isKindOfClass:[UITableViewCell class]]) {
                cell.detailTextLabel.text = status;
            }
        } else {
            self.modalInPresentation = NO;
            self.tableView.userInteractionEnabled = YES;
            [self removeActivityIndicatorFrom:cell];
            if ([cell isKindOfClass:[UITableViewCell class]]) {
                cell.detailTextLabel.text = [status localizedDescription];
            }
            NSData *errorData = ((NSError *)status).userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
            NSString *errorStr = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
            NSLog(@"[MSA] Error: %@", errorStr);
            showDialog(localize(@"Error", nil), errorStr);
        }
    } else if (success) {
        if (self.whenItemSelected != nil) {
            self.whenItemSelected();
        }
        [self removeActivityIndicatorFrom:cell];
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark - UIPopoverPresentationControllerDelegate
- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller traitCollection:(UITraitCollection *)traitCollection {
    return UIModalPresentationNone;
}

#pragma mark - ASWebAuthenticationPresentationContextProviding
- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session {
    if (UIApplication.sharedApplication.windows.count == 0) {
        return nil;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

@end

