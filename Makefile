RDOC?=	rdoc

.PHONY: docs
docs:
	$(RDOC) --visibility=private -x ./vendor 
