/*
 ============================================================================
 Name        : mem.c
 Author      : hev <r@hev.cc>
 Copyright   : Copyright (c) 2021 hev
 Description : Memory
 ============================================================================
 */

#include <stdlib.h>

#define WEAK __attribute__((weak))

WEAK void
hev_free (void *ptr)
{
    free (ptr);
}

WEAK void *
hev_malloc (size_t size)
{
    return malloc (size);
}

WEAK void *
hev_calloc (size_t nmemb, size_t size)
{
    return calloc (nmemb, size);
}
