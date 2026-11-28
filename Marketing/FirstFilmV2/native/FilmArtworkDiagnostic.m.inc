// Read-only capture diagnostic. This never supplies artwork to the product.
static void LTPFilmArtworkProbe(id raw, BOOL identityValid, NSError *sourceError) {
    const char *directory = getenv("FILM_V2_OUTPUT");
    if (!directory) return;
    NSMutableDictionary *report = [@{@"rawClass": raw ? NSStringFromClass([raw class]) : @"nil",
        @"rawIsDescriptor": @([raw isKindOfClass:NSAppleEventDescriptor.class]),
        @"rawIsSBObject": @([raw isKindOfClass:SBObject.class]),
        @"identityValid": @(identityValid), @"sourceErrorCode": @(sourceError.code),
        @"scope": @"Actual current Music artwork read; no injection into playback snapshot"} mutableCopy];
    id resolved = raw;
    @try {
        if ([resolved isKindOfClass:SBObject.class]) resolved = [resolved get];
        report[@"resolvedClass"] = resolved ? NSStringFromClass([resolved class]) : @"nil";
        report[@"resolvedIsDescriptor"] = @([resolved isKindOfClass:NSAppleEventDescriptor.class]);
        if ([resolved isKindOfClass:NSAppleEventDescriptor.class]) {
            report[@"descriptorType"] = @([(NSAppleEventDescriptor *)resolved descriptorType]);
            resolved = [(NSAppleEventDescriptor *)resolved data];
        }
        report[@"unwrappedIsData"] = @([resolved isKindOfClass:NSData.class]);
        if ([resolved isKindOfClass:NSData.class]) {
            report[@"unwrappedByteCount"] = @([resolved length]);
            if (identityValid && [resolved length] > 0 && [resolved length] <= 8 * 1024 * 1024) {
                NSString *path = [[NSString stringWithUTF8String:directory] stringByAppendingPathComponent:@"actual-player-artwork-probe.bin"];
                [resolved writeToFile:path atomically:YES];
            }
        }
    } @catch (NSException *exception) {
        report[@"probeExceptionName"] = exception.name ?: @"unknown";
        report[@"probeExceptionReason"] = exception.reason ?: @"unknown";
    }
    NSString *path = [[NSString stringWithUTF8String:directory] stringByAppendingPathComponent:@"artwork-bridge-probe.json"];
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:path atomically:YES];
    NSLog(@"FILM_ARTWORK_PROBE %@",report);
}
