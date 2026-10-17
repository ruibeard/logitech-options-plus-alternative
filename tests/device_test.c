#include "device.h"
#include <assert.h>
#include <string.h>

/* Minimal wire facts from OpenLogi 42af6f4's reviewed control captures.
 * Only the nine control-info bytes needed by this decoder are retained.
 * Upstream captures are reference evidence, not local hardware verification.
 */
static void test_reviewed_control_tables(void) {
    static const uint8_t master3s[][9] = {
        {0x00, 0x50, 0x00, 0x38, 0x01, 0x00, 0x01, 0x01, 0x04},
        {0x00, 0x51, 0x00, 0x39, 0x01, 0x00, 0x01, 0x01, 0x04},
        {0x00, 0x52, 0x00, 0x3a, 0x31, 0x00, 0x02, 0x03, 0x05},
        {0x00, 0x53, 0x00, 0x3c, 0x31, 0x00, 0x02, 0x03, 0x05},
        {0x00, 0x56, 0x00, 0x3e, 0x31, 0x00, 0x02, 0x03, 0x05},
        {0x00, 0xc3, 0x00, 0xa9, 0x31, 0x00, 0x02, 0x03, 0x05},
        {0x00, 0xc4, 0x00, 0x9d, 0x31, 0x00, 0x02, 0x03, 0x05},
        {0x00, 0xd7, 0x00, 0xb4, 0xa0, 0x00, 0x03, 0x00, 0x03},
    };
    static const uint8_t master4[][9] = {
        {0x00, 0x50, 0x00, 0x38, 0x01, 0x00, 0x01, 0x00, 0x04},
        {0x00, 0x51, 0x00, 0x39, 0x01, 0x00, 0x01, 0x00, 0x04},
        {0x00, 0x52, 0x00, 0x3a, 0x31, 0x00, 0x02, 0x03, 0x05},
        {0x00, 0x53, 0x00, 0x3c, 0x31, 0x00, 0x02, 0x03, 0x05},
        {0x00, 0x56, 0x00, 0x3e, 0x31, 0x00, 0x02, 0x03, 0x05},
        {0x00, 0xc3, 0x00, 0x9c, 0x31, 0x00, 0x02, 0x03, 0x05},
        {0x00, 0xc4, 0x00, 0x9d, 0x31, 0x00, 0x02, 0x03, 0x05},
        {0x01, 0xa0, 0x01, 0x09, 0x31, 0x00, 0x02, 0x03, 0x05},
        {0x00, 0xd7, 0x00, 0xb4, 0xa0, 0x00, 0x03, 0x00, 0x03},
    };
    const uint8_t (*tables[])[9] = {master3s, master4};
    const size_t counts[] = {sizeof(master3s)/sizeof(master3s[0]), sizeof(master4)/sizeof(master4[0])};
    for (size_t model=0; model<2; ++model) {
        unsigned logical_mask=0, diverted_count=0, haptic_count=0;
        for (size_t row=0; row<counts[model]; ++row) {
            MXControl control;
            assert(mx_control_from_report(tables[model][row],9,&control));
            if (row<2) assert(!control.divertible && control.slot==-1);
            if (control.slot>=0) {
                unsigned bit=1u<<(unsigned)control.slot;
                assert(!(logical_mask & bit));
                logical_mask |= bit;
            }
            diverted_count += control.divertible;
            if (control.cid==0xc3) assert(control.slot==3 && control.divertible);
            if (control.cid==0x1a0) {
                ++haptic_count;
                assert(control.slot==-1 && control.divertible && control.flags==0x531);
            }
            /* Unknown controls are retained by CID, not forced into a familiar slot. */
            if (control.cid==0xd7) assert(control.slot==-1 && control.divertible && !mx_control_name(control.cid));
            for (size_t truncated=0;truncated<9;++truncated)
                assert(!mx_control_from_report(tables[model][row],truncated,&control));
        }
        assert(logical_mask==0x1f);
        assert(diverted_count==(model==0 ? 6u : 7u));
        assert(haptic_count==model);
    }
    /* A model absent from the optional names registry can still supply an identity.
     * Runtime admission additionally requires a positive mouse identity and ping.
     */
    assert(!mx_device_lookup(0x046d,0x40fe));
    const uint8_t unknown_pairing[20]={0x11,0xff,0x83,0xb5,0x20,0,0,0x40,0xfe,0,0,2};
    MXReceiverPairing paired;
    assert(mx_parse_receiver_pairing(MX_RECEIVER_UNIFYING,1,unknown_pairing,20,&paired));
    assert(paired.product_id==0x40fe && paired.kind==2);
}

int main(void) {
    test_reviewed_control_tables();
    assert(mx_device_count() >= 2);
    const MXDeviceDefinition *mouse = mx_device_lookup(0x046d, 0xb023);
    assert(mouse && mouse == mx_device_at(0));
    assert(strcmp(mouse->name, "MX Master 3 for Mac") == 0);
    assert(mouse->bluetooth_direct);
    const uint16_t controls[MX_BUTTON_COUNT] = {0x0052, 0x0053, 0x0056, 0x00c3, 0x00c4};
    assert(memcmp(mouse->button_controls, controls, sizeof(controls)) == 0);
    const MXDeviceDefinition *m705=mx_device_lookup(0x046d,0x101b);
    assert(m705 && !m705->bluetooth_direct && m705->button_controls[3]==0x59 && !m705->button_controls[4]);
    /* Captured from the connected c52b receiver: slot 1, WPID 101b, mouse kind 2. */
    const uint8_t pairing[20] = {0x11,0xff,0x83,0xb5,0x20,0x18,0x08,0x10,0x1b,0x04,0,0x02,0x06};
    assert(mx_receiver_mouse(1,pairing,sizeof(pairing)) == m705);
    for (size_t length=0; length<sizeof(pairing); ++length)
        assert(!mx_receiver_mouse(1,pairing,length));
    assert(!mx_receiver_mouse(1,pairing,sizeof(pairing)+1));
    assert(!mx_receiver_mouse(0,pairing,sizeof(pairing)));
    assert(!mx_receiver_mouse(7,pairing,sizeof(pairing)));
    assert(!mx_receiver_mouse(2,pairing,sizeof(pairing))); /* Reply belongs to slot 1. */
    assert(!mx_receiver_mouse(1,NULL,sizeof(pairing)));
    uint8_t invalid[sizeof(pairing)];
    memcpy(invalid,pairing,sizeof(pairing));
    invalid[11]=1; /* A keyboard must never select the mouse controller. */
    assert(!mx_receiver_mouse(1,invalid,sizeof(invalid)));
    memcpy(invalid,pairing,sizeof(pairing));
    invalid[7]=0x40; invalid[8]=0xfe; /* Unregistered wireless product. */
    assert(!mx_receiver_mouse(1,invalid,sizeof(invalid)));
    invalid[7]=0xb0; invalid[8]=0x23; /* Bluetooth product IDs are not receiver WPIDs. */
    assert(!mx_receiver_mouse(1,invalid,sizeof(invalid)));
    for (size_t field=0; field<4; ++field) {
        memcpy(invalid,pairing,sizeof(pairing));
        invalid[field]^=1;
        assert(!mx_receiver_mouse(1,invalid,sizeof(invalid)));
    }
    memcpy(invalid,pairing,sizeof(pairing));
    invalid[4]=0x25;
    assert(mx_receiver_mouse(6,invalid,sizeof(invalid)) == m705);
    assert(!mx_device_lookup(0x046d, 0xffff));
    assert(!mx_device_lookup(0xffff, 0xb023));
    assert(!mx_device_lookup(0x1046d, 0xb023));
    assert(!mx_device_at(mx_device_count()));
    assert(!mx_device_at(SIZE_MAX));
    assert(mx_receiver_kind(0xc548) == MX_RECEIVER_BOLT);
    assert(mx_receiver_kind(0xc52b) == MX_RECEIVER_UNIFYING);
    assert(mx_receiver_kind(0x1c548) == MX_RECEIVER_NONE);
    assert(mx_receiver_kind(0xffff) == MX_RECEIVER_NONE);
    MXReceiverPairing identity;
    assert(mx_parse_receiver_pairing(MX_RECEIVER_UNIFYING,1,pairing,20,&identity));
    assert(identity.product_id == 0x101b && identity.kind == 2);
    uint8_t bolt[20] = {0x11,0xff,0x83,0xb5,0x52,0x22,0x42,0xb0,1,2,3,4};
    assert(mx_parse_receiver_pairing(MX_RECEIVER_BOLT,2,bolt,20,&identity));
    assert(identity.product_id == 0xb042 && identity.kind == 2 && identity.online);
    assert(identity.unit_id[0] == 1 && identity.unit_id[3] == 4);
    bolt[5] |= 0x40;
    assert(mx_parse_receiver_pairing(MX_RECEIVER_BOLT,2,bolt,20,&identity));
    assert(!identity.online);
    assert(!mx_parse_receiver_pairing(MX_RECEIVER_BOLT,1,bolt,20,&identity));
    for (size_t length=0; length<20; ++length)
        assert(!mx_parse_receiver_pairing(MX_RECEIVER_BOLT,2,bolt,length,&identity));
    assert(!mx_parse_receiver_pairing(MX_RECEIVER_NONE,2,bolt,20,&identity));
    for (size_t field=0; field<5; ++field) {
        uint8_t malformed[20]; memcpy(malformed,bolt,20); malformed[field]^=1;
        assert(!mx_parse_receiver_pairing(MX_RECEIVER_BOLT,2,malformed,20,&identity));
    }
    uint8_t newer_m705[20]; memcpy(newer_m705,pairing,20);
    newer_m705[7]=0x40; newer_m705[8]=0x6d;
    assert(mx_parse_receiver_pairing(MX_RECEIVER_UNIFYING,1,newer_m705,20,&identity));
    assert(identity.product_id == 0x406d && identity.kind == 2);
    /* Registry names must not invent a thumb control for this generation. */
    const MXDeviceDefinition *m705_new = mx_device_lookup(0x046d,0x406d);
    for (size_t button=0;button<MX_BUTTON_COUNT;++button) assert(!m705_new->button_controls[button]);
    assert(!mx_parse_receiver_pairing(MX_RECEIVER_BOLT,2,bolt,20,NULL));
    /* Master4 real upstream fixture rows: left click not divertible; panel is. */
    const uint8_t left[] = {0,0x50,0,0x38,1,0,1,0,4};
    const uint8_t haptic[] = {1,0xa0,1,9,0x31,0,2,3,5};
    MXControl control;
    assert(mx_control_from_report(left,sizeof(left),&control));
    assert(control.cid == 0x50 && control.slot == -1 && !control.divertible);
    assert(mx_control_from_report(haptic,sizeof(haptic),&control));
    assert(control.cid == 0x1a0 && control.slot == -1 && control.divertible);
    assert(control.flags == 0x531);
    assert(mx_control_slot(0xc3) == 3 && mx_control_slot(0x59) == 3);
    for (size_t length=0; length<9; ++length)
        assert(!mx_control_from_report(haptic,length,&control));
    assert(!mx_control_from_report(NULL,9,&control));
    assert(!mx_control_from_report(haptic,9,NULL));
    assert(mx_control_slot(0xbd)==1 && mx_control_slot(0xcf)==2);
    assert(mx_control_slot(0xfd)==4 && mx_control_slot(0xffff)==-1);
    assert(!mx_control_name(0xffff));
    assert(strcmp(mx_control_name(0x1a0),"Haptic panel")==0);
    assert(mx_device_lookup(0x046d,0xb042));
    assert(mx_device_lookup(0x046d,0x406d));
    return 0;
}
