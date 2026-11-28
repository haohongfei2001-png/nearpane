/* Decode real CF/AX result objects through the production decoder. No window
 * queries or writes: options=0 may mix successful values and per-item errors. */
#include "../../../Engine/nearpane-window-engine/src/spaces/binding-attributes.h"
#include <stdbool.h>
#include <stdio.h>

static unsigned passed, failed;
static void check(const char *name, bool condition) {
    if (condition) passed++;
    else { failed++; fprintf(stderr, "FAIL: %s\n", name); }
}
static CFArrayRef four(CFTypeRef role, CFTypeRef subrole, CFTypeRef minimized, CFTypeRef fullscreen) {
    const void *values[] = { role, subrole, minimized, fullscreen };
    return CFArrayCreate(NULL, values, 4, &kCFTypeArrayCallBacks);
}
static bool decoded(CFArrayRef values, AXError batch, CFIndex index, CFTypeID type,
                    CFTypeRef expected, AXError error) {
    NPStageBindingValue observed = np_stage_binding_value(values, batch, index, type);
    return observed.value == expected && observed.error == error;
}

int main(void) {
    CFTypeID string = CFStringGetTypeID(), boolean = CFBooleanGetTypeID();
    CFArrayRef values = four(kAXWindowRole, kAXStandardWindowSubrole, kCFBooleanFalse, kCFBooleanFalse);
    check("role is borrowed without changing identity", decoded(values, kAXErrorSuccess, 0, string, kAXWindowRole, kAXErrorSuccess));
    check("standard subrole", decoded(values, kAXErrorSuccess, 1, string, kAXStandardWindowSubrole, kAXErrorSuccess));
    check("minimized false", decoded(values, kAXErrorSuccess, 2, boolean, kCFBooleanFalse, kAXErrorSuccess));
    check("fullscreen false", decoded(values, kAXErrorSuccess, 3, boolean, kCFBooleanFalse, kAXErrorSuccess));
    check("batch transport error is preserved", decoded(values, kAXErrorCannotComplete, 0, string, NULL, kAXErrorCannotComplete));
    check("batch unsupported error is preserved", decoded(values, kAXErrorAttributeUnsupported, 3, boolean, NULL, kAXErrorAttributeUnsupported));
    check("negative index", decoded(values, kAXErrorSuccess, -1, string, NULL, kAXErrorFailure));
    check("past-end index", decoded(values, kAXErrorSuccess, 4, boolean, NULL, kAXErrorFailure));
    CFRelease(values);

    AXError unavailable = kAXErrorCannotComplete, unsupported = kAXErrorAttributeUnsupported, success = kAXErrorSuccess;
    AXValueRef unavailableValue = AXValueCreate(kAXValueAXErrorType, &unavailable);
    AXValueRef unsupportedValue = AXValueCreate(kAXValueAXErrorType, &unsupported);
    AXValueRef successValue = AXValueCreate(kAXValueAXErrorType, &success);
    if (!unavailableValue || !unsupportedValue || !successValue) {
        check("AX error fixture creation", false);
        if (unavailableValue) CFRelease(unavailableValue);
        if (unsupportedValue) CFRelease(unsupportedValue);
        if (successValue) CFRelease(successValue);
        return 2;
    }
    values = four(unavailableValue, kAXStandardWindowSubrole, kCFBooleanFalse, kCFBooleanTrue);
    check("per-role timeout remains unavailable", decoded(values, kAXErrorSuccess, 0, string, NULL, kAXErrorCannotComplete));
    check("another field survives role timeout", decoded(values, kAXErrorSuccess, 1, string, kAXStandardWindowSubrole, kAXErrorSuccess));
    check("fullscreen true is visible after earlier timeout", decoded(values, kAXErrorSuccess, 3, boolean, kCFBooleanTrue, kAXErrorSuccess));
    CFRelease(values);

    values = four(kAXButtonRole, unsupportedValue, unavailableValue, kCFBooleanFalse);
    check("wrong role string remains available for rejection", decoded(values, kAXErrorSuccess, 0, string, kAXButtonRole, kAXErrorSuccess));
    check("per-subrole unsupported remains a rejection", decoded(values, kAXErrorSuccess, 1, string, NULL, kAXErrorAttributeUnsupported));
    check("per-minimized timeout is separate from other rejections", decoded(values, kAXErrorSuccess, 2, boolean, NULL, kAXErrorCannotComplete));
    check("later field remains inspectable", decoded(values, kAXErrorSuccess, 3, boolean, kCFBooleanFalse, kAXErrorSuccess));
    CFRelease(values);

    values = four(kCFNull, kAXStandardWindowSubrole, kCFNull, successValue);
    check("null role has no value", decoded(values, kAXErrorSuccess, 0, string, NULL, kAXErrorNoValue));
    check("null minimized does not become false", decoded(values, kAXErrorSuccess, 2, boolean, NULL, kAXErrorNoValue));
    check("wrapped success is not an attribute value", decoded(values, kAXErrorSuccess, 3, boolean, NULL, kAXErrorFailure));
    CFRelease(values);

    int zero = 0;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &zero);
    CGPoint point = CGPointZero;
    AXValueRef pointValue = AXValueCreate(kAXValueCGPointType, &point);
    if (!number || !pointValue) {
        check("typed fixture creation", false);
    } else {
        values = four(kCFBooleanFalse, pointValue, number, CFSTR("false"));
        check("boolean is not a role string", decoded(values, kAXErrorSuccess, 0, string, kCFBooleanFalse, kAXErrorFailure));
        check("non-error AXValue is not a subrole", decoded(values, kAXErrorSuccess, 1, string, pointValue, kAXErrorFailure));
        check("zero number is not minimized false", decoded(values, kAXErrorSuccess, 2, boolean, number, kAXErrorFailure));
        check("false string is not fullscreen false", decoded(values, kAXErrorSuccess, 3, boolean, CFSTR("false"), kAXErrorFailure));
        CFRelease(values);
    }
    if (number) CFRelease(number);
    if (pointValue) CFRelease(pointValue);

    const void *shortValues[] = { kAXWindowRole, kAXStandardWindowSubrole, kCFBooleanFalse };
    values = CFArrayCreate(NULL, shortValues, 3, &kCFTypeArrayCallBacks);
    check("partial array is rejected even for its first field", decoded(values, kAXErrorSuccess, 0, string, NULL, kAXErrorFailure));
    CFRelease(values);
    check("missing array", decoded(NULL, kAXErrorSuccess, 0, string, NULL, kAXErrorFailure));
    check("wrong container type", decoded((CFArrayRef)kCFBooleanFalse, kAXErrorSuccess, 0, string, NULL, kAXErrorFailure));
    CFRelease(unavailableValue);
    CFRelease(unsupportedValue);
    CFRelease(successValue);
    printf("{\"schema\":1,\"status\":\"%s\",\"passed\":%u,\"failed\":%u,\"windowWrites\":0}\n",
           failed ? "FAIL" : "PASS", passed, failed);
    return failed ? 1 : 0;
}
