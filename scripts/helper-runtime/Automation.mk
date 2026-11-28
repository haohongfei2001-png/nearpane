NearpaneAutomation: NearpaneAutomation.o $(LINK_PYTHON_DEPS)
	$(LINKCC) $(PY_CORE_LDFLAGS) $(LINKFORSHARED) -o $@ NearpaneAutomation.o $(LINK_PYTHON_OBJS) $(LIBS) $(MODLIBS) $(SYSLIBS)

NearpaneAutomation.o: NearpaneAutomation.c $(PYTHON_HEADERS)
	$(CC) -c $(PY_CORE_CFLAGS) -o $@ $<
