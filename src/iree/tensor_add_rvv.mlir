module {
  func.func @add_1024(
      %lhs: tensor<1024xf32>,
      %rhs: tensor<1024xf32>
  ) -> tensor<1024xf32> attributes {iree.module.export} {
    %sum = arith.addf %lhs, %rhs : tensor<1024xf32>
    return %sum : tensor<1024xf32>
  }
}
