*-----------------------------------------------------------------------------
* mainrespip_b.s -- second body fragment of the fast MAIN_RES image: the MLI
* param block ($93F0) and the RX ring ($9400), padded to $9600. PUT by the
* mainres-pip-*.s drivers immediately after `put ssc_common`. Shared by both CPU
* builds. No PUT of its own (nested PUT is a no-op in Merlin32 v1.2b2).
*-----------------------------------------------------------------------------
*---- MLI param block (pinned $93F0; install-pip references MLI_PARAMS) ------
            ds    $93F0-*,$00
mli_params  dfb   2
int_num     dfb   0
            da    ssc_irq

*---- RX ring (page-aligned $9400) -------------------------------------------
            ds    $9400-*,$00
rx_buf      ds    256

*---- pad to $9600 (6 pages exactly) -----------------------------------------
            ds    $9600-*,$00
