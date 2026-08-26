"""Entry point used by the kernelspec: `python -m aro_kernel -f {connection_file}`."""

from ipykernel.kernelapp import IPKernelApp

from .kernel import AROKernel

if __name__ == "__main__":
    IPKernelApp.launch_instance(kernel_class=AROKernel)
