#ifndef NP_SPACES_BINDING_ATTRIBUTES_H
#define NP_SPACES_BINDING_ATTRIBUTES_H
#include <ApplicationServices/ApplicationServices.h>

/* Borrowed values from one options=0 AX multiple-attribute result. A successful
 * batch can contain a separate AXError or CFNull at any position; it is never
 * evidence that the attribute is false or has its usual value. No native reads
 * occur here, so mixed transport errors and positive denials are all inspected. */
typedef struct { CFTypeRef value; AXError error; } NPStageBindingValue;
static inline NPStageBindingValue np_stage_binding_value(CFArrayRef values, AXError result,
                                                         CFIndex index, CFTypeID expected) {
    if(result!=kAXErrorSuccess)return (NPStageBindingValue){NULL,result};
    if(!values || CFGetTypeID(values)!=CFArrayGetTypeID() || CFArrayGetCount(values)!=4 || index<0 || index>=4)
        return (NPStageBindingValue){NULL,kAXErrorFailure};
    CFTypeRef value=CFArrayGetValueAtIndex(values,index);
    if(!value || CFGetTypeID(value)==CFNullGetTypeID())return (NPStageBindingValue){NULL,kAXErrorNoValue};
    if(CFGetTypeID(value)==AXValueGetTypeID() && AXValueGetType((AXValueRef)value)==kAXValueAXErrorType) {
        AXError error=kAXErrorFailure;
        if(!AXValueGetValue((AXValueRef)value,kAXValueAXErrorType,&error) || error==kAXErrorSuccess)error=kAXErrorFailure;
        return (NPStageBindingValue){NULL,error};
    }
    return (NPStageBindingValue){value,CFGetTypeID(value)==expected?kAXErrorSuccess:kAXErrorFailure};
}
#endif
