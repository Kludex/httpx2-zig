#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <stdint.h>

typedef struct {
    const uint8_t *ptr;
    size_t len;
} Slice;

typedef struct {
    Slice name;
    Slice value;
} Header;

typedef struct {
    uint16_t status;
    Slice headers;
    Slice body;
    const char *error_name;
} Result;

typedef struct Client Client;

extern Client *createClient(void);
extern void freeClient(Client *client);
extern Result *sendRequest(Client *client, Slice method, Slice url, const Header *headers, size_t headers_len, Slice body);
extern void freeResult(Result *result);

typedef struct {
    Client *client;
} ClientHandle;

static const char *capsule_name = "httpx2_zig.Client";

static void destroy_client(PyObject *capsule) {
    ClientHandle *handle = PyCapsule_GetPointer(capsule, capsule_name);
    if (handle == NULL) {
        PyErr_Clear();
        return;
    }
    if (handle->client != NULL) freeClient(handle->client);
    PyMem_Free(handle);
}

static PyObject *create_client(PyObject *self, PyObject *unused) {
    (void)self;
    (void)unused;
    ClientHandle *handle = PyMem_Malloc(sizeof(*handle));
    if (handle == NULL) return PyErr_NoMemory();
    handle->client = createClient();
    if (handle->client == NULL) {
        PyMem_Free(handle);
        return PyErr_NoMemory();
    }
    PyObject *capsule = PyCapsule_New(handle, capsule_name, destroy_client);
    if (capsule == NULL) {
        freeClient(handle->client);
        PyMem_Free(handle);
    }
    return capsule;
}

static PyObject *close_client(PyObject *self, PyObject *capsule) {
    (void)self;
    ClientHandle *handle = PyCapsule_GetPointer(capsule, capsule_name);
    if (handle == NULL) return NULL;
    if (handle->client != NULL) {
        freeClient(handle->client);
        handle->client = NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *send_request(PyObject *self, PyObject *args) {
    (void)self;
    PyObject *capsule, *headers_obj;
    const char *method, *url, *body;
    Py_ssize_t method_len, url_len, body_len;
    if (!PyArg_ParseTuple(args, "Oy#y#Oy#", &capsule, &method, &method_len, &url, &url_len,
                          &headers_obj, &body, &body_len)) return NULL;
    ClientHandle *handle = PyCapsule_GetPointer(capsule, capsule_name);
    if (handle == NULL) return NULL;
    if (handle->client == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "Zig transport is closed");
        return NULL;
    }
    PyObject *headers_seq = PySequence_Fast(headers_obj, "headers must be a sequence");
    if (headers_seq == NULL) return NULL;
    Py_ssize_t count = PySequence_Fast_GET_SIZE(headers_seq);
    Header *headers = PyMem_New(Header, count == 0 ? 1 : count);
    if (headers == NULL) {
        Py_DECREF(headers_seq);
        return PyErr_NoMemory();
    }
    for (Py_ssize_t i = 0; i < count; i++) {
        PyObject *pair = PySequence_Fast_GET_ITEM(headers_seq, i);
        if (!PyTuple_Check(pair) || PyTuple_GET_SIZE(pair) != 2 ||
            !PyBytes_Check(PyTuple_GET_ITEM(pair, 0)) || !PyBytes_Check(PyTuple_GET_ITEM(pair, 1))) {
            PyErr_SetString(PyExc_TypeError, "each header must be a pair of bytes");
            PyMem_Free(headers);
            Py_DECREF(headers_seq);
            return NULL;
        }
        PyObject *name = PyTuple_GET_ITEM(pair, 0);
        PyObject *value = PyTuple_GET_ITEM(pair, 1);
        headers[i].name = (Slice){(const uint8_t *)PyBytes_AS_STRING(name), (size_t)PyBytes_GET_SIZE(name)};
        headers[i].value = (Slice){(const uint8_t *)PyBytes_AS_STRING(value), (size_t)PyBytes_GET_SIZE(value)};
    }
    Result *result;
    Py_BEGIN_ALLOW_THREADS
    result = sendRequest(handle->client,
                         (Slice){(const uint8_t *)method, (size_t)method_len},
                         (Slice){(const uint8_t *)url, (size_t)url_len},
                         headers, (size_t)count,
                         (Slice){(const uint8_t *)body, (size_t)body_len});
    Py_END_ALLOW_THREADS
    PyMem_Free(headers);
    Py_DECREF(headers_seq);
    if (result == NULL) return PyErr_NoMemory();
    PyObject *error = result->error_name == NULL ? Py_NewRef(Py_None) : PyUnicode_FromString(result->error_name);
    PyObject *header_bytes = PyBytes_FromStringAndSize((const char *)result->headers.ptr, (Py_ssize_t)result->headers.len);
    PyObject *body_bytes = PyBytes_FromStringAndSize((const char *)result->body.ptr, (Py_ssize_t)result->body.len);
    PyObject *response = NULL;
    if (error != NULL && header_bytes != NULL && body_bytes != NULL)
        response = Py_BuildValue("HNNN", result->status, header_bytes, body_bytes, error);
    else {
        Py_XDECREF(error);
        Py_XDECREF(header_bytes);
        Py_XDECREF(body_bytes);
    }
    freeResult(result);
    return response;
}

static PyMethodDef methods[] = {
    {"create_client", create_client, METH_NOARGS, NULL},
    {"close_client", close_client, METH_O, NULL},
    {"send_request", send_request, METH_VARARGS, NULL},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef module = {
    PyModuleDef_HEAD_INIT,
    "_httpx2_zig",
    NULL,
    -1,
    methods,
};

PyMODINIT_FUNC PyInit__httpx2_zig(void) {
    return PyModule_Create(&module);
}
