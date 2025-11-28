// V30 (8086) Test Program for Pico Monitor, written in C.
// This version includes stack initialization and is K&R-compatible for bcc.

// Forward declaration for the main logic.
void main();

// The _start function will be the entry point for the program.
void _start() {
    // Use bcc's inline assembler to set the stack pointer to a safe address.
    // as86 (bcc's assembler) uses '#' for immediate values.
    asm("mov sp, #0x8000");
    
    // After setting up the stack, call the main C function.
    main();
}

// Main C logic, same as before.
void main() {
    // Declare all variables at the top of the function.
    char *mem;
    unsigned char a;
    unsigned char b;

    // Assign values to the variables.
    mem = (char *)0x0100;
    a = 1;
    b = 2;
    
    // Perform the calculation and store the result.
    *mem = a + b;
    
    // Halt the CPU by entering an infinite loop.
    while(1);
}
