
(in-package "C")
(proclaim '(special
	    *defprint-pretty* *event-info* *event-note-threshold*
	    *instruction-formats* *instructions* *current-fixup* *first-fixup*
	    *next-location* *code-vector* *labels* *current-label*
	    *last-label-created* *assembler-nodes* *current-assembler-node*
	    *last-assembler-node-created* *other-code-vector*
	    *other-next-location* *fixup-offset* *fixup-offset-map*
	    *fixup-last-shortening* *result-fixups* *source-path-tree*
	    *sc-numbers* *sb-list* *template-names* *sc-names* *sb-names*
	    *meta-sc-numbers* *primitive-type-names* *move-costs* *save-scs*
	    *save-costs* *restore-costs* *parsed-vops*
	    *compiler-error-context* *code-segment* *elsewhere*))
